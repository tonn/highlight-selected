{Range, CompositeDisposable, Emitter, MarkerLayer} = require 'atom'
StatusBarView = require './status-bar-view'
escapeRegExp = require './escape-reg-exp'

module.exports =
class HighlightedAreaView

  constructor: ->
    @emitter = new Emitter
    @markerLayers = []
    @resultCount = 0
    @enable()
    @listenForTimeoutChange()
    @activeItemSubscription = atom.workspace.onDidChangeActivePaneItem =>
      @debouncedHandleSelection()
      @subscribeToActiveTextEditor()
    @subscribeToActiveTextEditor()
    @listenForStatusBarChange()

  destroy: =>
    clearTimeout(@handleSelectionTimeout)
    @activeItemSubscription.dispose()
    @selectionSubscription?.dispose()
    @statusBarView?.removeElement()
    @statusBarTile?.destroy()
    @statusBarTile = null

  onDidAddMarker: (callback) =>
    Grim = require 'grim'
    Grim.deprecate("Please do not use. This method will be removed.")
    @emitter.on 'did-add-marker', callback

  onDidAddSelectedMarker: (callback) =>
    Grim = require 'grim'
    Grim.deprecate("Please do not use. This method will be removed.")
    @emitter.on 'did-add-selected-marker', callback

  onDidAddMarkerForEditor: (callback) =>
    @emitter.on 'did-add-marker-for-editor', callback

  onDidAddSelectedMarkerForEditor: (callback) =>
    @emitter.on 'did-add-selected-marker-for-editor', callback

  onDidRemoveAllMarkers: (callback) =>
    @emitter.on 'did-remove-marker-layer', callback

  disable: =>
    @disabled = true
    @removeMarkers()

  enable: =>
    @disabled = false
    @debouncedHandleSelection()

  setStatusBar: (statusBar) =>
    @statusBar = statusBar
    @setupStatusBar()

  debouncedHandleSelection: =>
    clearTimeout(@handleSelectionTimeout)
    @handleSelectionTimeout = setTimeout =>
      @handleSelection()
    , atom.config.get('highlight-selected.timeout')

  listenForTimeoutChange: ->
    atom.config.onDidChange 'highlight-selected.timeout', =>
      @debouncedHandleSelection()

  subscribeToActiveTextEditor: ->
    @selectionSubscription?.dispose()

    editor = @getActiveEditor()
    return unless editor

    @selectionSubscription = new CompositeDisposable

    @selectionSubscription.add(
      editor.onDidAddSelection @debouncedHandleSelection
    )
    @selectionSubscription.add(
      editor.onDidChangeSelectionRange @debouncedHandleSelection
    )
    @handleSelection()

  getActiveEditor: ->
    atom.workspace.getActiveTextEditor()

  getActiveEditors: ->
    atom.workspace.getPanes().map (pane) ->
      activeItem = pane.activeItem
      activeItem if activeItem and activeItem.constructor.name == 'TextEditor'

  escapeRegExp1: (str) =>
    return str.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&")

  handleSelection: =>
    @removeMarkers()

    return if @disabled

    editor = @getActiveEditor()

    return unless editor
    return if editor.getLastSelection().isEmpty()

    if atom.config.get('highlight-selected.onlyHighlightWholeWords')
      return unless @isWordSelected(editor.getLastSelection())

    @selections = editor.getSelections()

    text = @escapeRegExp1(@selections[0].getText())

    return if text.length < atom.config.get('highlight-selected.minimumLength')

    regexFlags = 'g'
    if atom.config.get('highlight-selected.ignoreCase')
      regexFlags = 'gi'

    @ranges = []

    if atom.config.get('highlight-selected.onlyHighlightWholeWords')
      if text.indexOf("\$") isnt -1 \
      and editor.getGrammar()?.name in ['PHP', 'HACK']
        text = text.replace("\$", "\$\\b")
      else
        text =  "\\b" + text
      text = text + "\\b"

    @resultCount = 0
    if atom.config.get('highlight-selected.highlightInPanes')
      @getActiveEditors().forEach (editor) =>
        @highlightSelectionInEditor(editor, text, regexFlags)
    else
      @highlightSelectionInEditor(editor, text, regexFlags)

    @statusBarElement?.updateCount(@resultCount)

  highlightSelectionInEditor: (editor, regexSearch, regexFlags) ->
    markerLayer = editor?.addMarkerLayer()
    return unless markerLayer?
    markerLayerForHiddenMarkers = editor.addMarkerLayer()
    @markerLayers.push(markerLayer)
    @markerLayers.push(markerLayerForHiddenMarkers)

    range =  [[0, 0], editor.getEofBufferPosition()]

    editor.scanInBufferRange new RegExp(regexSearch, regexFlags), range,
      (result) =>
        @resultCount += 1
        if @showHighlightOnSelectedWord(result.range, @selections)
          marker = markerLayerForHiddenMarkers.markBufferRange(result.range)
          @emitter.emit 'did-add-selected-marker', marker
          @emitter.emit 'did-add-selected-marker-for-editor',
            marker: marker
            editor: editor
        else
          marker = markerLayer.markBufferRange(result.range)
          @emitter.emit 'did-add-marker', marker
          @emitter.emit 'did-add-marker-for-editor',
            marker: marker
            editor: editor
    editor.decorateMarkerLayer(markerLayer, {
      type: 'highlight',
      class: @makeClasses()
    })

  makeClasses: ->
    className = 'highlight-selected'
    if atom.config.get('highlight-selected.lightTheme')
      className += ' light-theme'

    if atom.config.get('highlight-selected.highlightBackground')
      className += ' background'
    className

  showHighlightOnSelectedWord: (range, selections) ->
    return false unless atom.config.get(
      'highlight-selected.hideHighlightOnSelectedWord')
    outcome = false
    for selection in selections
      selectionRange = selection.getBufferRange()
      outcome = (range.start.column is selectionRange.start.column) and
                (range.start.row is selectionRange.start.row) and
                (range.end.column is selectionRange.end.column) and
                (range.end.row is selectionRange.end.row)
      break if outcome
    outcome

  removeMarkers: =>
    @markerLayers.forEach (markerLayer) ->
      markerLayer.destroy()
    @markerLayers = []
    @statusBarElement?.updateCount(0)
    @emitter.emit 'did-remove-marker-layer'

  isWordSelected: (selection) ->
    if selection.getBufferRange().isSingleLine()
      selectionRange = selection.getBufferRange()
      lineRange = @getActiveEditor().bufferRangeForBufferRow(
        selectionRange.start.row)
      nonWordCharacterToTheLeft =
        selectionRange.start.isEqual(lineRange.start) or
        @isNonWordCharacterToTheLeft(selection)
      nonWordCharacterToTheRight =
        selectionRange.end.isEqual(lineRange.end) or
        @isNonWordCharacterToTheRight(selection)

      nonWordCharacterToTheLeft and nonWordCharacterToTheRight
    else
      false

  isNonWordCharacter: (character) ->
    nonWordCharacters = atom.config.get('editor.nonWordCharacters')
    new RegExp("[ \t#{escapeRegExp(nonWordCharacters)}]").test(character)

  isNonWordCharacterToTheLeft: (selection) ->
    selectionStart = selection.getBufferRange().start
    range = Range.fromPointWithDelta(selectionStart, 0, -1)
    @isNonWordCharacter(@getActiveEditor().getTextInBufferRange(range))

  isNonWordCharacterToTheRight: (selection) ->
    selectionEnd = selection.getBufferRange().end
    range = Range.fromPointWithDelta(selectionEnd, 0, 1)
    @isNonWordCharacter(@getActiveEditor().getTextInBufferRange(range))

  setupStatusBar: =>
    return if @statusBarElement?
    return unless atom.config.get('highlight-selected.showInStatusBar')
    @statusBarElement = new StatusBarView()
    @statusBarTile = @statusBar.addLeftTile(
      item: @statusBarElement.getElement(), priority: 100)

  removeStatusBar: =>
    return unless @statusBarElement?
    @statusBarTile?.destroy()
    @statusBarTile = null
    @statusBarElement = null

  listenForStatusBarChange: =>
    atom.config.onDidChange 'highlight-selected.showInStatusBar', (changed) =>
      if changed.newValue
        @setupStatusBar()
      else
        @removeStatusBar()
