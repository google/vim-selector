" Copyright 2015 Google Inc. All rights reserved.
"
" Licensed under the Apache License, Version 2.0 (the "License");
" you may not use this file except in compliance with the License.
" You may obtain a copy of the License at
"
"     http://www.apache.org/licenses/LICENSE-2.0
"
" Unless required by applicable law or agreed to in writing, software
" distributed under the License is distributed on an "AS IS" BASIS,
" WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
" See the License for the specific language governing permissions and
" limitations under the License.

""
" @section Introduction, intro
" @library
" Utility methods to provide a way to create a SelectorWindow. See
" @function(#OpenWindow) for details.

let s:QUIT_KEY = 'q'
let s:HELP_KEY = 'H'

if !exists('s:selectors_by_buffer_number')
  let s:selectors_by_buffer_number = {}
endif

" Clears out special global variables which legacy ResetMapper func can use to
" configure the selector.
" This is called on every selector#OpenWindow call.
function! s:ResetDefaultGlobalMappings() abort
  unlet! g:Sw_SetExtraOptions
  unlet! g:Sw_SetSyntax
  unlet! g:sw_key_mappings
  unlet! g:sw_max_win_height
  unlet! g:sw_min_win_height
endfunction

" The default keymappings.
function! s:GetDefaultKeyMappings() abort
  return {
      \ '<CR>' : ['s:DefaultAfterKey', 'Close', 'Do something'],
      \ s:HELP_KEY : [
          \ 'selector#ToggleCurrentHelp',
          \ 'NoOp',
          \ 'Toggle verbose help messages'],
      \ s:QUIT_KEY : ['selector#NoOp', 'Close', 'Close the window']
      \ }
endfunction

" Create the full key mappings dict.
function! s:ExpandedKeyMappings(mappings) abort
  let l:window_action_mapping = {
      \ 'Close' : 'selector#CloseWindow',
      \ 'Return' : 'selector#ReturnToWindow',
      \ 'NoOp'  : 'selector#NoOp'
      \ }
  " A map from the key (scrubbed of <>s) to:
  "   - The main action
  "   - the window action
  "   - the help item
  "   - the actual key press (with the brackets)
  let l:expanded_mappings = {}
  for l:keypress in keys(a:mappings)
    let l:items = a:mappings[l:keypress]
    " Check if the keypress is just left or right pointies (<>)
    let l:scrubbed = l:keypress
    if l:keypress =~# '\m<\|>'
      " Left and right pointies must be scrubbed -- they have special meaning
      " when used in the context of creating key mappings, which is where the
      " scrubbed keypresses are used.
      let l:scrubbed = substitute(substitute(l:keypress, '<', '_Gr', 'g'),
          \ '>', '_Ls', 'g')
    endif
    let l:window_action = get(l:window_action_mapping,
        \ l:items[1], l:items[1])
    let l:expanded_mappings[l:scrubbed] =
        \ [l:items[0], l:window_action, l:items[2], l:keypress]
  endfor
  return l:expanded_mappings
endfunction

""
" Unzips {infolist}, a list of selector entries, into line text and data.
" Each selector entry may be either a string, or a pair (LINE, DATA) stored in a
" list.
"
" Returns a flat list of lines and a dict mapping line numbers to data.
function! s:SplitLinesAndData(infolist) abort
  let l:lines = []
  let l:data = {}
  for l:index in range(len(a:infolist))
    unlet! l:entry l:datum
    let l:entry = a:infolist[l:index]
    if maktaba#value#IsList(l:entry)
      let [l:line, l:datum] = l:entry
    else
      let l:line = maktaba#ensure#IsString(l:entry)
    endif
    call add(l:lines, l:line)
    if exists('l:datum')
      " Vim line numbers are 1-based.
      let l:data[l:index + 1] = l:datum
    endif
  endfor
  return [l:lines, l:data]
endfunction


function! s:DoLegacyConfig(selector, ApplyLegacyConfig) abort
  " Reset the defaults.
  call s:ResetDefaultGlobalMappings()
  call maktaba#function#Call(a:ApplyLegacyConfig)
  if exists('g:Sw_SetSyntax')
    call a:selector.WithSyntax(function(g:Sw_SetSyntax))
  endif
  if exists('g:Sw_SetExtraOptions')
    call a:selector.WithExtraOptions(function(g:Sw_SetExtraOptions))
  endif
  return a:selector
endfunction


""
" @dict Selector
" Representation of a set of data for a user to select from, e.g. list of files.
" It can be created with @function(#Create), configured with syntax
" highlighting, key mappings, etc. and shown as a vim window.


""
" @public
" Creates a @dict(Selector) from {infolist} that can be configured and shown.
"
" Each entry in {infolist} may be either a line to display, or a 2-item list
" containing `[LINE, DATA]`. If present, DATA will be passed to the action
" function as a second argument.
function! selector#Create(infolist) abort
  let l:selector = {
      \ '_infolist': a:infolist,
      \ '_name': '__SelectorWindow__',
      \ '_is_verbose': 0,
      \ '_ApplySyntax': function('selector#DefaultSetSyntax'),
      \ '_ApplyExtraOptions': function('selector#DefaultExtraOptions'),
      \ '_GetHelpLines': function('selector#DoGetHelpLines'),
      \ 'WithMappings': function('selector#DoWithMappings'),
      \ 'WithSyntax': function('selector#DoWithSyntax'),
      \ 'WithExtraOptions': function('selector#DoWithExtraOptions'),
      \ 'WithName': function('selector#DoWithName'),
      \ 'Show': function('selector#DoShow'),
      \ 'ToggleHelp': function('selector#DoToggleHelp'),
      \ '_GetLineData': function('selector#DoGetLineData')}
  return l:selector.WithMappings({})
endfunction


""
" @dict Selector.WithMappings
" Set {keymappings} to use in the selector window. Must have the form: >
"   'keyToPress': [
"       ActionFunction({line}, [datum]),
"       'SelectorWindowAction',
"       'Help Text']
" <
" Where the "ActionFunction" is the name of a function you specify, which
" takes one or two arguments:
"   1. line: The contents of the line on which the "keyToPress" was pressed.
"   2. datum: data associated with the line when selector was created, if line
"      was initialized as a 2-item list.
"
" And where the "SelectorWindowAction" must be one of the following:
"  - "Close" -- close the SelectorWindow before completing the action
"  - "Return" -- Return to previous window and keep the Selector Window open
"  - "NoOp" -- Perform no action (keeping the SelectorWindow open).
function! selector#DoWithMappings(keymappings) dict abort
  let l:custom_mappings = maktaba#ensure#IsDict(a:keymappings)
  let l:mappings = extend(
      \ s:GetDefaultKeyMappings(), l:custom_mappings, 'force')
  let self._mappings = s:ExpandedKeyMappings(l:mappings)
  return self
endfunction


""
" @dict Selector.WithSyntax
" Configures an {ApplySyntax} function to be called in the selector window.
" This will by applied in addition to standard syntax rules for rendering the
" help header, etc.
function! selector#DoWithSyntax(ApplySyntax) dict abort
  let self._ApplySyntax = maktaba#ensure#IsCallable(a:ApplySyntax)
  return self
endfunction


""
" @dict Selector.WithExtraOptions
" Configures {ApplyExtraOptions} for additional window-local settings for
" selector window.
" If not configured, the default extra options just disable 'number'.
function! selector#DoWithExtraOptions(ApplyExtraOptions) dict abort
  let self._ApplyExtraOptions = maktaba#ensure#IsCallable(a:ApplyExtraOptions)
  return self
endfunction


""
" @dict Selector.WithName
" Configures {name} to show as the window name on the selector.
" If not configured, the default name is "__SelectorWindow__".
function! selector#DoWithName(name) dict abort
  let self._name = maktaba#ensure#IsString(a:name)
  return self
endfunction


""
" @dict Selector.Show
" Shows a selector window for the @dict(Selector) with [minheight], [maxheight],
" and [position].
" @default minheight=5
" @default maxheight=25
" @default position='botright'
function! selector#DoShow(...) dict abort
  let l:min_win_height = (a:0 >= 1 && a:1 isnot -1) ?
      \ maktaba#ensure#IsNumber(a:1) : 5
  let l:max_win_height = (a:0 >= 2 && a:2 isnot -1) ?
      \ maktaba#ensure#IsNumber(a:2) : 25
  let l:position = maktaba#ensure#IsString(get(a:, 3, 'botright'))

  " Show one empty line at the bottom of the window.
  " (2 is correct -- I know it looks bizarre)
  let l:win_size = len(self._infolist) + 2
  if l:win_size > l:max_win_height
    let l:win_size = l:max_win_height
  elseif l:win_size < l:min_win_height
    let l:win_size = l:min_win_height
  endif

  let s:current_savedview = winsaveview()
  let s:curpos_holder = getpos(".")
  let s:last_winnum = winnr()

  " Open the window in the specified window position.  Typically, this opens up
  " a flat window on the bottom (as with split).
  execute l:position l:win_size 'new'
  let s:selectors_by_buffer_number[bufnr('%')] = self
  call s:SetWindowOptions(self)
  silent execute 'file' self._name
  let [l:lines, l:data] = s:SplitLinesAndData(self._infolist)
  let b:selector_lines_data = l:data
  call s:InstantiateKeyMaps(self._mappings)
  setlocal noreadonly
  setlocal modifiable
  call maktaba#buffer#Overwrite(1, line('$'), l:lines)
  " Add the help comments at the top (do this last so cursor stays below it).
  call append(0, self._GetHelpLines())
  setlocal readonly
  setlocal nomodifiable

  " Restore the previous windows view
  let l:buffer_window = winnr()
  call selector#ReturnToWindow()
  call winrestview(s:current_savedview)
  execute l:buffer_window  'wincmd w'

  return self
endfunction


""
" @private
" Gets data associated with {lineno}, as passed in 2-item form of infolist when
" creating a selector with @function(#Create).
" @throws NotFound if no data was configured for requested line.
function! selector#DoGetLineData(lineno) dict abort
  let l:lineno = a:lineno - len(self._GetHelpLines())
  if has_key(b:selector_lines_data, l:lineno)
    return b:selector_lines_data[l:lineno]
  endif
  throw maktaba#error#NotFound('Associated data for selector line %d', l:lineno)
endfunction


""
" @public
" @usage {infolist} [ResetMapper] [window_name] [window_position]
" WARNING: This is a legacy function and will soon be deprecated and removed.
" Open a selector window named [window_name] based on {infolist}, a list of
" selector entries.
"
" Each entry in {infolist} may be either a line to display, or a 2-item list
" containing [LINE, DATA]. If present, DATA will be passed to the action
" function as a second argument.
"
" Entries are loaded into a new buffer-window located at [window_position], with
" mappings loaded from `g:sw_key_mappings`, syntax applied via `g:Sw_SetSyntax`,
" and window options applied using `g:Sw_SetExtraOptions`.
"
" [ResetMapper] is a function that says how to configure the selector with key
" mappings and syntax settings via special variables `g:Sw_SetSyntax`,
" `g:Sw_SetExtraOptions`, `g:sw_key_mappings`, `g:sw_min_win_height`, and
" `g:sw_max_win_height`. (These special variables are actually local to the
" selector and are cleared out before opening a new selector.)
"
" [ResetMapper] usually looks like the following: >
"   function! MyResetMapper()
"     let g:sw_key_mappings = {
"         \ '<CR>' : [ 'MyOpenFunc', 'Close', 'Open a file'],
"         \ 'd'    : [ 'MyDeleteFunc', 'Close', 'Delete a file']
"         \ }
"     let g:Sw_SetSyntax = 'MySyntaxResetter'
"   endfunction
" <
"
" @default window_name="__SelectorWindow__"
" @default window_position="botright"
function! selector#OpenWindow(infolist, ...) abort
  let l:selector = selector#Create(a:infolist)
  if a:0 >= 1
    let l:ResetMapper = maktaba#ensure#IsCallable(a:1)
    call s:DoLegacyConfig(l:selector, l:ResetMapper)
  endif
  if a:0 >= 2
    call l:selector.WithName(maktaba#ensure#IsString(a:2))
  endif
  if has_key(g:, 'sw_key_mappings')
    call l:selector.WithMappings(g:sw_key_mappings)
  endif
  let l:min_win_height = get(g:, 'sw_min_win_height', -1)
  let l:max_win_height = get(g:, 'sw_max_win_height', -1)
  if a:0 >= 3
    let l:window_position = maktaba#ensure#IsString(a:3)
    call l:selector.Show(l:min_win_height, l:max_win_height, l:window_position)
  else
    call l:selector.Show(l:min_win_height, l:max_win_height)
  endif
endfunction

" Set the Window Options for the created window.
function! s:SetWindowOptions(selector) abort
  if v:version >= 700
    setlocal buftype=nofile
    setlocal bufhidden=delete
    setlocal noswapfile
    setlocal readonly
    setlocal cursorline
    setlocal nolist
    setlocal nomodifiable
    setlocal nospell
  endif
  call maktaba#function#Call(a:selector._ApplyExtraOptions)
  if has('syntax')
    call maktaba#function#Call(a:selector._ApplySyntax)
    call s:BaseSyntax()
  endif
endfunction

" Comment out lines -- used in creating help text
function! s:CommentLines(str)
  let l:out = []
  for l:comment_lines in split(a:str, '\n')
    if l:comment_lines[0] ==# '"'
      call add(l:out, l:comment_lines)
    else
      call add(l:out, '" ' . l:comment_lines)
    endif
  endfor
  return l:out
endfunction

""
" @private
" Get a list of header lines for the selector window that will be displayed as
" comments at the top. Documents all key mappings if `self.verbose` is 1,
" otherwise just documents that H toggles help.
function! selector#DoGetHelpLines() dict abort
  if self._is_verbose
    " Map from comments to keys.
    let l:comments_keys = {}
    for l:items in values(self._mappings)
      let l:keycomment = l:items[2]
      let l:key = l:items[3]
      if has_key(l:comments_keys, l:keycomment)
        let l:comments_keys[l:keycomment] = l:comments_keys[l:keycomment]
            \ . ',' . l:key
      else
        let l:comments_keys[l:keycomment] = l:key
      endif
    endfor

    " Map from keys to comments.
    let l:keys_comments = {}
    for l:line_comment in keys(l:comments_keys)
      let l:key = l:comments_keys[l:line_comment]
      let l:keys_comments[key] = l:line_comment
    endfor

    let l:lines = []
    for l:key in sort(keys(l:keys_comments))
      call extend(l:lines,
          \ s:CommentLines(printf("%s\t: %s", l:key, l:keys_comments[l:key])))
    endfor
    return l:lines
  else
    return s:CommentLines("Press 'H' for more options.")
  endif
endfunction

""
" @private
function! selector#ToggleCurrentHelp(...) abort
  let l:selector = s:selectors_by_buffer_number[bufnr('%')]
  call l:selector.ToggleHelp()
endfunction

""
" @dict Selector.ToggleHelp
" Toggle whether verbose help is shown for the selector.
function! selector#DoToggleHelp() dict abort
  " TODO(dbarnett): Don't modify buffer if none exists.
  setlocal noreadonly
  setlocal modifiable
  let l:len_help = len(self._GetHelpLines())
  let self._is_verbose = !self._is_verbose
  call maktaba#buffer#Overwrite(1, l:len_help, self._GetHelpLines())
  setlocal readonly
  setlocal nomodifiable
endfunction

" Initialize the key bindings
function! s:InstantiateKeyMaps(mappings) abort
  for l:scrubbed_key in keys(a:mappings)
    let l:items = a:mappings[l:scrubbed_key]
    let l:actual_key = l:items[3]
    let l:mapping = 'nnoremap <buffer> <silent> <nowait> ' . l:actual_key
        \ . " :call selector#KeyCall('" . l:scrubbed_key . "')<CR>"
    execute l:mapping
  endfor
endfunction

""
" @private
function! selector#DefaultExtraOptions() abort
  setlocal nonumber
endfunction

" The base syntax defines the comment syntax in the selector window, which is
" used for the Help menus.
function! s:BaseSyntax() abort
  syntax region SelectorComment start='^"' end='$'
      \ contains=SelectorKey,SelectorKey2,SelectorKey3
  syntax match SelectorKey "'<\?\w*>\?'" contained
  syntax match SelectorKey2 '<\w*>\t:\@=' contained
  syntax match SelectorKey3
      \ '\(\w\|<\|>\)\+\(,\(\w\|<\|>\)\+\)*\t:\@=' contained
  highlight default link SelectorComment Comment
  highlight default link SelectorKey Keyword
  highlight default link SelectorKey2 Keyword
  highlight default link SelectorKey3 Keyword
endfunction

""
" @private
" The default syntax function.  Mostly, this exists to test that setting-syntax
" works, and it's expected that this will be overwritten
function! selector#DefaultSetSyntax() abort
  syntax match filepart '/\?\(\w*/\)*\w*' nextgroup=javaext
  syntax match javaext '[.][a-z]*$'
  highlight default link filepart Directory
  highlight default link javaext Function
endfunction

""
" @private
" Perform the key action.
"
" The {scrubbed_key} allows us to retrieve the original key.
function! selector#KeyCall(scrubbed_key) abort
  let l:selector = s:selectors_by_buffer_number[bufnr('%')]
  let l:contents = getline('.')
  let l:action_func = l:selector._mappings[a:scrubbed_key][0]
  let l:window_func = l:selector._mappings[a:scrubbed_key][1]
  if l:contents[0] ==# '"' &&
      \ a:scrubbed_key !=# s:QUIT_KEY
      \ && a:scrubbed_key !=# s:HELP_KEY
    return
  endif
  try
    let l:datum = l:selector._GetLineData(line('.'))
  catch /ERROR(NotFound):/
    " No data associated with line. Ignore and leave l:datum undefined.
  endtry
  call maktaba#function#Call(l:window_func)
  if exists('l:datum')
    call maktaba#function#Call(l:action_func, [l:contents, l:datum])
  else
    call maktaba#function#Call(l:action_func, [l:contents])
  endif
endfunction

" A default key mapping function -- not very useful.
function! s:DefaultAfterKey(line, ...) abort
  execute 'edit ' . a:line
endfunction

""
" @private
" Close the window and return to the initial-calling window.
function! selector#CloseWindow() abort
  bdelete
  call selector#ReturnToWindow()
endfunction

""
" @private
" Return the user to the previous window
function! selector#ReturnToWindow() abort
  execute s:last_winnum . 'wincmd w'
  call setpos('.', s:curpos_holder)
  call winrestview(s:current_savedview)
endfunction

""
" @private
" A default function
function! selector#NoOp(...) abort
endfunction
