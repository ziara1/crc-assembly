%ifndef MACRO_PRINT_ASM
%define MACRO_PRINT_ASM

; Nie definiujemy tu żadnych stałych, żeby nie było konfliktu ze stałymi
; zdefiniowanymi w pliku włączającym ten plik.

; Wypisuje napis podany jako pierwszy argument, a potem szesnastkowo zawartość
; rejestru podanego jako drugi argument i kończy znakiem nowej linii.
; Nie modyfikuje zawartości żadnego rejestru ogólnego przeznaczenia ani rejestru
; znaczników.
%macro print 2
  jmp     %%begin
%%descr: db %1
%%begin:
  push    %2                      ; Wartość do wypisania będzie na stosie. To działa również dla %2 = rsp.
  lea     rsp, [rsp - 16]         ; Zrób miejsce na stosie na bufor. Nie modyfikuj znaczników.
  pushf
  push    rax
  push    rcx
  push    rdx
  push    rsi
  push    rdi
  push    r11

  mov     eax, 1                  ; SYS_WRITE
  mov     edi, eax                ; STDOUT
  lea     rsi, [rel %%descr]      ; Napis jest w sekcji .text.
  mov     edx, %%begin - %%descr  ; To jest długość napisu.
  syscall

  mov     rdx, [rsp + 72]         ; To jest wartość do wypisania.
  mov     ecx, 16                 ; Pętla loop ma być wykonana 16 razy.
%%next_digit:
  mov     al, dl
  and     al, 0Fh                 ; Pozostaw w al tylko jedną cyfrę.
  cmp     al, 9
  jbe     %%is_decimal_digit      ; Skocz, gdy 0 <= al <= 9.
  add     al, 'A' - 10 - '0'      ; Wykona się, gdy 10 <= al <= 15.
%%is_decimal_digit:
  add     al, '0'                 ; Wartość '0' to kod ASCII zera.
  mov     [rsp + rcx + 55], al    ; W al jest kod ASCII cyfry szesnastkowej.
  shr     rdx, 4                  ; Przesuń rdx w prawo o jedną cyfrę.
  loop    %%next_digit

  mov     [rsp + 72], byte `\n`   ; Zakończ znakiem nowej linii. Intencjonalnie
                                  ; nadpisuje na stosie niepotrzebną już wartość.

  mov     eax, 1                  ; SYS_WRITE
  mov     edi, eax                ; STDOUT
  lea     rsi, [rsp + 56]         ; Bufor z napisem jest na stosie.
  mov     edx, 17                 ; Napis ma 17 znaków.
  syscall
  
  pop     r11
  pop     rdi
  pop     rsi
  pop     rdx
  pop     rcx
  pop     rax
  popf
  lea     rsp, [rsp + 24]
%endmacro

%endif




section .bss
    buffer resb 4096           ; Bufor o rozmiarze 4096 bajtów
    crc_poly_num resq 1        ; Miejsce na przekształcony wielomian CRC

section .data
    err_msg db 'Error', 10     ; Komunikat o błędzie zakończony nowym wierszem
    err_msg_len equ $ - err_msg

section .text
    global _start

_start:
    ; Wczytaj parametry programu
    mov rdi, [rsp+8]           ; argv[0] (nazwa programu)
    mov rsi, [rsp+16]          ; argv[1] (nazwa pliku)
    mov rdx, [rsp+24]          ; argv[2] (wielomian CRC)

    ; Sprawdź, czy wszystkie argumenty są podane
    test rsi, rsi
    jz error_exit
    test rdx, rdx
    jz error_exit

    ; Konwertuj wielomian CRC do liczby
    mov rbx, rdx               ; Ustaw wskaźnik na początek łańcucha
    xor rax, rax               ; Wyczyść rax (miejsce na wynik)
    xor rcx, rcx               ; Wyczyść rcx (do przesunięć)

convert_loop:
    mov dl, byte [rbx]
    test dl, dl
    jz conversion_done         ; Koniec łańcucha
    sub dl, '0'
    jb error_exit              ; Niepoprawny znak
    cmp dl, 1
    ja error_exit              ; Niepoprawny znak
    shl rax, 1                 ; Przesuń wynik w lewo o 1 bit
    or rax, rdx
    inc rbx
    inc cl
    jmp convert_loop

conversion_done:
    mov [crc_poly_num], rax    ; Zapisz wynik do zmiennej
    print "", rcx


    ; Otwórz plik
    mov rax, 2                 ; sys_open
    mov rdi, rsi               ; Nazwa pliku
    mov rsi, 0                 ; Oflag: O_RDONLY
    syscall
    test rax, rax
    js error_exit
    mov rdi, rax               ; Zapisz deskryptor pliku


    ; Odczytuj zawartość pliku do bufora
read_loop:
    mov rax, 0                 ; sys_read
    mov rsi, buffer            ; Bufor
    mov rdx, 4096              ; Rozmiar bufora
    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd
    test rax, rax
    jz close_and_exit          ; Koniec pliku
    ; (Tutaj przetworz dane z bufora)

    jmp read_loop              ; Kontynuuj odczyt

close_and_exit:
    ; Zamknij plik
    mov rax, 3                 ; sys_close
    syscall
    jmp exit

error_exit:
    ; Wypisz komunikat o błędzie
    mov rax, 1                 ; sys_write
    mov rdi, 2                 ; Deskryptor pliku: stderr
    mov rsi, err_msg
    mov rdx, err_msg_len
    syscall

    ; Zamknij plik, jeśli otwarty
    test rdi, rdi
    jz exit                    ; Plik nie został otwarty
    mov rax, 3                 ; sys_close
    syscall

exit:
    ; Zakończ program
    mov rax, 60                ; sys_exit
    xor rdi, rdi               ; Kod wyjścia: 0
    syscall
