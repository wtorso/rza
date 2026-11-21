let s:failures = []

function! s:Check(condition, message) abort
    if !a:condition
        call add(s:failures, a:message)
    endif
endfunction

function! s:GroupAt(line, column) abort
    return synIDattr(synID(a:line, a:column, 1), 'name')
endfunction

function! s:CheckGroup(line, column, expected) abort
    call s:Check(s:GroupAt(a:line, a:column) ==# a:expected,
        \ printf('line %d column %d: expected %s, got %s',
        \ a:line, a:column, a:expected, s:GroupAt(a:line, a:column)))
endfunction

execute 'set runtimepath^=' . getcwd() . '/editors/vim'
filetype plugin on
syntax enable
edit editors/tests/fixtures/sample.rza

call s:Check(&filetype ==# 'rza', 'filetype must be rza, got ' . &filetype)
call s:Check(&commentstring ==# '; %s',
    \ 'commentstring must be ; %s, got ' . &commentstring)
call s:CheckGroup(1, 1, 'rzaKeyword')
call s:CheckGroup(1, 8, 'rzaLayout')
call s:CheckGroup(1, 19, 'rzaScalarType')
call s:CheckGroup(1, 30, 'rzaScalarType')
call s:CheckGroup(2, 21, 'rzaLayout')
call s:Check(s:GroupAt(1, 8) !=# s:GroupAt(1, 19),
    \ 'layout and scalar types must differ')
call s:CheckGroup(2, 14, 'rzaConstant')
call s:CheckGroup(3, 26, 'rzaConstant')
call s:CheckGroup(4, 5, 'rzaRegister')
call s:CheckGroup(5, 5, 'rzaRegister')
call s:CheckGroup(4, 10, 'rzaNumber')
call s:CheckGroup(5, 11, 'rzaNumber')
call s:CheckGroup(2, 27, 'rzaNumber')
call s:CheckGroup(7, 24, 'rzaNumber')
call s:CheckGroup(6, 25, 'rzaField')
call s:CheckGroup(7, 27, 'rzaField')
call s:CheckGroup(8, 6, 'rzaLabel')
call s:CheckGroup(10, 1, 'rzaComment')
call s:CheckGroup(10, 3, 'rzaComment')
call s:CheckGroup(10, 10, 'rzaComment')
call s:CheckGroup(10, 14, 'rzaComment')
call s:Check(s:GroupAt(11, 5) ==# '', '%r16 must not have a syntax group')
call s:CheckGroup(12, 18, 'rzaScalarType')
call s:CheckGroup(12, 30, 'rzaScalarType')
call s:CheckGroup(12, 38, 'rzaScalarType')
call s:CheckGroup(12, 55, 'rzaScalarType')
call s:CheckGroup(18, 21, 'rzaScalarType')
call s:CheckGroup(18, 31, 'rzaScalarType')
call s:CheckGroup(19, 19, 'rzaScalarType')

let s:opcodes = [
    \ 'cav', 'res', 'med', 'view', 'raise', 'decay', 'probe', 'load', 'loadb',
    \ 'mov', 'store', 'storeb', 'slt', 'inc', 'dec', 'await', 'print',
    \ 'jmp', 'brz', 'brnz', 'call', 'proc', 'casc', 'acasc', 'endc', 'ret',
    \ 'layout', 'add', 'sub', 'mul', 'div', 'mod', 'and', 'or', 'xor',
    \ 'shl', 'shr', 'ushr', 'cadd', 'csub', 'cmul', 'cinc', 'cdec', 'crc32c']
enew!
call setline(1, s:opcodes)
runtime! syntax/rza.vim
for line in range(1, len(s:opcodes))
    call s:CheckGroup(line, 1, 'rzaKeyword')
endfor

let s:typed = []
for base in ['mov', 'load', 'store', 'add', 'sub', 'mul', 'inc', 'dec',
        \ 'cadd', 'csub', 'cmul', 'cinc', 'cdec', 'and', 'or', 'xor',
        \ 'div', 'mod', 'shl', 'ushr']
    for type in ['i8', 'u8', 'i16', 'u16', 'i32', 'u32', 'i64', 'u64']
        call add(s:typed, base . '.' . type)
    endfor
endfor
for opcode in ['shr.i8', 'slt.i8', 'ult.u8', 'shr.i16', 'slt.i16', 'ult.u16',
        \ 'shr.i32', 'slt.i32', 'ult.u32', 'shr.i64', 'slt.i64', 'ult.u64']
    call add(s:typed, opcode)
endfor
call s:Check(len(s:typed) == 172, 'typed matrix must contain 172 spellings')
enew!
call setline(1, s:typed)
runtime! syntax/rza.vim
for line in range(1, len(s:typed))
    call s:CheckGroup(line, 1, 'rzaKeyword')
    call s:CheckGroup(line, stridx(s:typed[line - 1], '.') + 2, 'rzaKeyword')
endfor

let s:inactive = [
    \ 'shr.u8', 'slt.u8', 'ult.i8', 'shr.u16', 'slt.u16', 'ult.i16',
    \ 'shr.u32', 'slt.u32', 'ult.i32', 'shr.u64', 'slt.u64', 'ult.i64',
    \ 'ult', 'loadb.u8', 'loadb.u16', 'loadb.u32', 'loadb.u64',
    \ 'crc32c.i32', 'print.i32', 'cvt.i64', 'cvt.u64', 'add.f32', 'add.f64']
let s:asserted_inactive = 0
enew!
call setline(1, s:inactive)
runtime! syntax/rza.vim
for line in range(1, len(s:inactive))
    let opcode = s:inactive[line - 1]
    call s:Check(s:GroupAt(line, 1) !=# 'rzaKeyword',
        \ opcode . ' base must not be a typed keyword')
    let dot = stridx(opcode, '.')
    if dot >= 0
        call s:Check(s:GroupAt(line, dot + 2) !=# 'rzaKeyword',
            \ opcode . ' suffix must not be a typed keyword')
    endif
    let s:asserted_inactive += 1
endfor
call s:Check(s:asserted_inactive == len(s:inactive),
    \ 'every inactive spelling must be asserted')

enew!
call setline(1, 'loop:')
runtime! syntax/rza.vim
call s:CheckGroup(1, 1, 'rzaLabel')
enew!
call setline(1, 'proc convert(input_m: ro, result_m: rw):')
runtime! syntax/rza.vim
call s:CheckGroup(1, 6, 'rzaLabel')

if len(s:failures) > 0
    for message in s:failures
        echomsg message
    endfor
    cquit
else
    echom 'Vim syntax and filetype checks passed'
    qa!
endif
