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
" Utility methods to provide a way to create a SelectorWindow. See
" @function(#OpenWindow) for details.

let s:QUIT_KEY = 'q'
let s:HELP_KEY = 'H'

" This defines the Default SelectorWindow configuration.
" This is called on every selector#OpenWindow call.
function! s:SetDefaultGlobalMappings() abort
  ""
  " Function to set extra window options.
  let g:Sw_SetExtraOptions = 's:DefaultExtraOptions'
  ""
  " Function to set the syntax for the window.
  let g:Sw_SetSyntax = 's:DefaultSetSyntax'
  ""
  " Additional key mappings to use in the selector window. Must have the form:
  " >
  "   'keyToPress' : [
  "       'ActionFunction',
  "       'SelectorWindowAction',
  "       'Help Text']
  " <
  " Where the "ActionFunction" is the name of a function you specify, which
  " takes exactly _two_ arguments --
  "  1. The contents of the line, on which the "keyToPress" was pressed.
  "  2. The contents of the entire selector buffer, minus the comments.
  "
  " And where the "SelectorWindowAction" must be one of the following:
  "  - "Close" -- close the SelectorWindow before completing the action
  "  - "Return" -- Return to previous window and keep the Selector Window open
  "  - "NoOp" -- Peform no action (keeping the SelectorWindow open).
  let g:sw_key_mappings = {}
  ""
  " Max window height [default=25]
  let g:sw_max_win_height = 25
  ""
  " Min window height [default=5]
  let g:sw_min_win_height = 5
endfunction

" The default keymappings.
function! s:GetDefaultKeyMappings() abort
  return {
      \ '<CR>' : ['s:DefaultAfterKey', 'Close', 'Do something'],
      \ s:HELP_KEY : ['s:ToggleHelp', 'NoOp', 'Toggle the help messages'],
      \ s:QUIT_KEY : ['selector#NoOp', 'Close', 'Close the window']
      \ }
endfunction

" Create the function refs in Vim.
function! s:CreateFunctionRefs() abort
  " Due to the below error, either, we need to unlet, or do a try-catch
  " Patch 7.2.402
  " Problem:  This gives a #705 error: let X = function('haslocaldir')
  "           let X = function('getcwd')
  call s:InitFunctionVariable('g:Sw_SetExtraOptions')
  call s:InitFunctionVariable('g:Sw_SetSyntax')
endfunction

" Create the full_key_mappings dict.
function! s:InitKeyMappings(mappings) abort
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
  let s:full_key_mappings = {}
  for l:keypress in keys(a:mappings)
    let l:items = a:mappings[keypress]
    " Check if the keypress is just left or right pointies (<>)
    let l:scrubbed = l:keypress
    if l:keypress =~# '\m<\|>'
      " Left and right pointies must be scrubbed -- they have special meaning
      " when used in the context of creating key mappings, which is where the
      " scrubbed keypresses are used.
      let l:scrubbed = substitute(substitute(keypress, '<', '_Gr', 'g'),
          \ '>', '_Ls', 'g')
    endif
    let l:window_action = get(l:window_action_mapping,
        \ l:items[1], l:items[1])
    let s:full_key_mappings[l:scrubbed] =
        \ [l:items[0], l:window_action, l:items[2], l:keypress]
  endfor
endfunction

" Make a first class function and return the function variable.
function! s:InitFunctionVariable(func_prefix) abort
  let l:funcvar = a:func_prefix . '_func'
  if exists(l:funcvar)
    unlet {l:funcvar}
  endif
  let {l:funcvar} = function({a:func_prefix})
  return l:funcvar
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


""
" @public
" @usage {infolist} [ResetMapper] [window_name] [window_position]
" Open a selector window named [window_name] based on {infolist}, a list of
" selector entries. Calls [ResetMapper] to initialize the buffer with key
" mappings and syntax settings. Entries are loaded into a new buffer-window
" located at [window_position] and window options are set using
" @setting(g:Sw_SetExtraOptions).
"
" Each entry in {infolist} may be either a line to display, or a 2-item list
" containing [LINE, DATA]. If present, DATA will be passed to the action
" function as a second argument.
"
" [ResetMapper] is a function that says how to reset the function mappings. It
" usually looks like the following:
" >
"   function! MyResetMapper()
"     let g:sw_key_mappings = {
"         \ '<CR>' : [ 'MyOpenFunc', 'Close', 'Open a file'],
"         \ 'd'    : [ 'MyDeleteFunc', 'Close', 'Delete a file']
"         \ }
"     let g:Sw_SetSyntax = 'MySyntaxResetter'
"   endfunction
" <
" See @section(config) for details about the different settings variables.
"
" @default ResetMapper="selector#NoOp"
" @default window_name="__SelectorWindow__"
" @default window_position="botright"
function! selector#OpenWindow(infolist, ...) abort
  let l:ResetMapper = maktaba#ensure#IsCallable(get(a:, 1, 'selector#NoOp'))
  let l:window_name = maktaba#ensure#IsString(get(a:, 2, '__SelectorWindow__'))
  let l:window_position = maktaba#ensure#IsString(get(a:, 3, 'botright'))

  " Reset the defaults.
  call s:SetDefaultGlobalMappings()
  " Initialize the user's variables.
  call call(function(l:ResetMapper), [])

  let l:mappings = extend(
      \ s:GetDefaultKeyMappings(), g:sw_key_mappings, 'force')
  call s:InitKeyMappings(l:mappings)
  call s:CreateFunctionRefs()

  " Show one empty line at the bottom of the window.
  " (2 is correct -- I know it looks bizarre)
  let l:win_size = len(a:infolist) + 2
  if l:win_size > g:sw_max_win_height
    let l:win_size = g:sw_max_win_height
  elseif l:win_size < g:sw_min_win_height
    let l:win_size = g:sw_min_win_height
  endif

  let s:current_savedview = winsaveview()
  let s:curpos_holder = getpos(".")
  let s:last_winnum = winnr()

  " Open the window in the specified window position.  Typically, this opens up
  " a flat window on the bottom (as with split).
  execute l:window_position . ' ' . l:win_size . 'new'
  call s:SetWindowOptions()
  silent execute 'file ' . l:window_name
  let [l:lines, l:data] = s:SplitLinesAndData(a:infolist)
  let b:selector_lines_data = l:data
  call s:InstantiateKeyMaps()
  setlocal noreadonly
  setlocal modifiable
  let s:verbose_help = 0
  call maktaba#buffer#Overwrite(1, line('$'), l:lines)
  " Add the help comments at the top (do this last so cursor stays below it).
  call append(0, s:GetHelpLines(0))
  setlocal readonly
  setlocal nomodifiable

  " Restore the previous windows view
  let buffer_window = winnr()
  call selector#ReturnToWindow()
  call winrestview(s:current_savedview)
  execute buffer_window  . 'wincmd w'
endfunction

" Set the Window Options for the created window.
function! s:SetWindowOptions() abort
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
  call call(g:Sw_SetExtraOptions_func, [])
  if has('syntax')
    if exists('g:Sw_SetSyntax')
      call call(g:Sw_SetSyntax_func, [])
    endif
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
" Get a list of header lines for the selector window that will be displayed as
" comments at the top. Documents all key mappings if {verbose} is 1, otherwise
" just documents that H toggles help.
function! s:GetHelpLines(verbose) abort
  if a:verbose
    " Map from comments to keys.
    let l:comments_keys = {}
    for l:items in values(s:full_key_mappings)
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
      call extend(l:lines, s:CommentLines( '' . l:key . "\t: "
          \ . l:keys_comments[l:key]))
    endfor
    return l:lines
  else
    return s:CommentLines("Press 'H' for more options.")
  endif
endfunction

function! s:ToggleHelp(...) abort
  let l:prev_read = &readonly
  let l:prev_mod = &modifiable
  setlocal noreadonly
  setlocal modifiable
  let l:len_help = len(s:GetHelpLines(s:verbose_help))
  let s:verbose_help = !s:verbose_help
  call maktaba#buffer#Overwrite(1, l:len_help, s:GetHelpLines(s:verbose_help))
  let &readonly = l:prev_read
  let &modifiable = l:prev_mod
endfunction

" Initialize the key bindings
function! s:InstantiateKeyMaps() abort
  for l:scrubbed_key in keys(s:full_key_mappings)
    let l:items = s:full_key_mappings[l:scrubbed_key]
    let l:actual_key = l:items[3]
    let l:mapping = 'nnoremap <buffer> <silent> ' . l:actual_key
        \ . " :call selector#KeyCall('" . l:scrubbed_key . "')<CR>"
    execute l:mapping
  endfor
endfunction

function! s:DefaultExtraOptions()
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

"The default syntax function.  Mostly, this exists to test that setting-syntax
"works, and it's expected that this will be overwritten
function! s:DefaultSetSyntax()
  syntax match filepart '/\?\(\w*/\)*\w*' nextgroup=javaext
  syntax match javaext '[.][a-z]*$'
  highlight default link filepart Directory
  highlight default link javaext Function
endfunction

" Perform the key action.
"
" The scrubbed_key allows us to retrieve the original key.
function! selector#KeyCall(scrubbed_key) abort
  let l:contents = getline('.')
  let l:action_func = s:full_key_mappings[a:scrubbed_key][0]
  let l:window_func = s:full_key_mappings[a:scrubbed_key][1]
  if l:contents[0] ==# '"' &&
      \ a:scrubbed_key !=# s:QUIT_KEY
      \ && a:scrubbed_key !=# s:HELP_KEY
    return
  endif
  let l:lineno = line('.') - len(s:GetHelpLines(s:verbose_help))
  if has_key(b:selector_lines_data, l:lineno)
    let l:datum = b:selector_lines_data[l:lineno]
  endif
  call call(l:window_func, [])
  if exists('l:datum')
    call call(l:action_func, [l:contents, l:datum])
  else
    call call(l:action_func, [l:contents])
  endif
endfunction

" A default key mapping function -- not very useful.
function! s:DefaultAfterKey(line, ...) abort
  execute 'edit ' . a:line
endfunction

" Close the window and return to the initial-calling window.
function! selector#CloseWindow() abort
  bdelete
  call selector#ReturnToWindow()
endfunction

" Return the user to the previous window
function! selector#ReturnToWindow() abort
  execute s:last_winnum . 'wincmd w'
  call setpos('.', s:curpos_holder)
  call winrestview(s:current_savedview)
endfunction

" A default function
function! selector#NoOp(...)
endfunction
