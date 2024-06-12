%ifndef MACRO_PRINT_ASM
%define MACRO_PRINT_ASM

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
    buffer resb 4096            ; Bufor o rozmiarze 4096 bajtów
    crc_poly resq 1             ; przekształcony wielomian CRC
    length resw 1               ; długość fragmentu (2 bajty)
    offset resd 1               ; przesunięcie fragmentu (4 bajty)
    output resb 65              ; maksymalnie 64 bity + null terminator

section .data
    crcTable times 256 dq 0     ; tablica 256 elementów 64-bitowych 
    dlugoscwyniku db 0          ; dlugosc ostatecznego wyniku


section .text
    global _start

_start:
    ; Wczytaj parametry programu
    mov rdi, [rsp+8]            ; argv[0] (nazwa programu)
    mov rsi, [rsp+16]           ; argv[1] (nazwa pliku)
    mov rdx, [rsp+24]           ; argv[2] (wielomian CRC)

    ; Sprawdź, czy wszystkie argumenty są podane
    test rsi, rsi
    jz error_exit
    test rdx, rdx
    jz error_exit

                                ; konwertuje wielomian CRC do liczby
    mov rbx, rdx                ; ustawia wskaźnik na początek stringa
    xor rax, rax                ; miejsce na wynik
    xor rcx, rcx                ; do przesunięć

convert_loop:
    mov dl, byte [rbx]
    test dl, dl
    jz conversion_done          ; koniec stringa
    sub dl, '0'
    jb error_exit               ; niepoprawny znak
    cmp dl, 1
    ja error_exit               ; niepoprawny znak
    shl rax, 1                  ; przesuwa wynik w lewo o 1 bit
    or rax, rdx
    inc rbx
    inc cl
    jmp convert_loop

conversion_done:
    mov rbx, 64
    mov [dlugoscwyniku], cl
    sub rbx, rcx
    mov cl, bl
    shl rax, cl
    mov [crc_poly], rax         ; zapisuje wielomian do zmiennej


crcInit:
    mov rcx, [rel crc_poly]     ; wielomian crc
    mov r8, 0x8000000000000000

    ; Dla każdego możliwego dzielnika (0-255)
    xor rdi, rdi                ; dzielnik = 0

crcLoop:
    mov eax, edi                ; eax = dzielnik tylko dolne 32 bity są ważne
    shl rax, 56                 ; remainder = dzielnik << (WIDTH - 8)
    mov rbx, rax                ; przenieś remainder do rbx
    mov rdx, 8

    ; Dla każdego bitu (od 8 do 0)
bitLoop:
    test rbx, r8                ; sprawdź, czy TOPBIT jest ustawiony
    jz noDivision

    ; Jeśli TOPBIT jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1
    xor rbx, rcx                ; remainder = remainder ^ wielomian
    jmp nextBit

noDivision:
    ; Jeśli TOPBIT nie jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1

nextBit:
    sub dl, 1                   ; bit--
    jnz bitLoop

    ; Przechowaj wynik w crcTable
    mov [crcTable + rdi*8], rbx ; crcTable[dzielnik] = remainder

    ; Następny dividend
    inc edi                     ; dzielnik++
    cmp edi, 256                ; sprawdź, czy dzielnik < 256
    jl crcLoop


    ; Otwórz plik
    mov rax, 2                  ; sys_open
    mov rdi, rsi                ; nazwa pliku
    mov rsi, 0                  ; Oflag: O_RDONLY
    syscall
    test rax, rax
    js error_exit
    mov rdi, rax                ; zapisuje deskryptor pliku

    xor r9, r9

read_fragment:
    ; Wczytaj 2 bajty długości fragmentu
    mov rax, 0                  ; sys_read
    mov rsi, length             ; bufor na długość fragmentu (2 bajty)
    mov rdx, 2                  ; wczytuje 2 bajty
    syscall
    test rax, rax
    js error_exit               ; wystąpił błąd
    test rax, rax
    jz error_exit               ; koniec pliku

    ; Przetwórz długość fragmentu (little-endian)
    movzx r8, word [length]     ; przechowuje długość fragmentu w r8


process_data:
    ; Sprawdź, czy długość fragmentu jest większa niż bufor

    cmp r8, 4096
    jbe .read_data              ; jeśli długość <= 4096, wczytaj dane
    ; Wczytuj dane w partiach po 4096 bajtów
.read_chunk:

    mov rax, 0                  ; sys_read
    mov rsi, buffer             ; bufor 4096 bajtowy
    mov rdx, 4096               ; wczytaj 4096 bajtów
    syscall
    test rax, rax
    js error_exit               ; wystąpił błąd
    test rax, rax
    jz error_exit               ; koniec pliku

    xor rbx, rbx
.crc_loop1:

    cmp rbx, rax
    jge .done1
    movzx r10, byte [rsi + rbx] ; Załaduj message[byte] do r10, rozszerzając do 64 bitów
    mov r11, r9                 ; Przenieś remainder do r11
    shr r11, 56                 ; Przesuń remainder w prawo o (64 - 8) bitów
    xor r10, r11                ; data = message[byte] ^ (remainder >> 56)

    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; Załaduj crcTable[data] do r11, rozszerzając do 64 bitów
    shl r9, 8                   ; Przesuń remainder w lewo o 8 bitów
    xor r9, r11                 ; remainder = crcTable[data] ^ (remainder << 8)

    inc rbx                     ; Zwiększ indeks (byte)
    jmp .crc_loop1              ; Przejdź do następnego bajtu

.done1:
    sub r8, rax                 ; Zmniejsz pozostałą długość fragmentu
    jmp process_data            ; Kontynuuj przetwarzanie danych

.read_data:
    mov rax, 0                  ; sys_read
    mov rsi, buffer             ; bufor 4096 bajtowy
    mov rdx, r8                 ; wczytuje pozostałe dane fragmentu

    syscall
    test rax, rax
    js error_exit               ; wystąpił błąd
    test rax, rax
    jz error_exit               ; koniec pliku

    xor rbx, rbx
.crc_loop2:
    cmp rbx, rax
    jge .done2
    movzx r10, byte [rsi + rbx] ; Załaduj message[byte] do r10, rozszerzając do 64 bitów
    mov r11, r9                 ; Przenieś remainder do r11
    shr r11, 56                 ; Przesuń remainder w prawo o (64 - 8) bitów
    xor r10, r11                ; data = message[byte] ^ (remainder >> 56)


    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; Załaduj crcTable[data] do r11, rozszerzając do 64 bitów

    shl r9, 8                   ; Przesuń remainder w lewo o 8 bitów
    xor r9, r11                 ; remainder = crcTable[data] ^ (remainder << 8)

    inc rbx                     ; Zwiększ indeks (byte)

    jmp .crc_loop2              ; Przejdź do następnego bajtu

.done2:


    ; Wczytaj 4 bajty przesunięcia fragmentu
    mov rax, 0                  ; sys_read
    mov rsi, offset             ; Bufor na przesunięcie fragmentu (4 bajty)
    mov rdx, 4                  ; Wczytaj 4 bajty
    syscall
    test rax, rax
    js error_exit               ; Wystąpił błąd
    test rax, rax
    jz error_exit               ; Koniec pliku

; Przetwórz przesunięcie fragmentu (little-endian, signed)
    movsxd rax, dword [offset]  ; Przenosi i rozszerza znak 32-bitowego offsetu do 64-bitowego rejestru

    ; Sprawdź, czy przesunięcie wskazuje na początek fragmentu
    movzx r8, word [length]     ; Przechowuje długość fragmentu w r8
    add r8, 6
    neg r8
    sub r8, rax
    test r8, r8
    jz close_and_exit

    ; Przesuń wskaźnik pliku o wartość przesunięcia
    mov rdx, rax                ; Przesunięcie
    mov rax, 8                  ; sys_lseek
    mov rsi, rdx                ; Przesunięcie
    mov rdx, 1                  ; SEEK_CUR
    syscall
    test rax, rax
    js error_exit               ; Wystąpił błąd

    jmp read_fragment           ; Wczytaj kolejny fragment



close_and_exit:
    ; Zamknij plik
    mov rax, 3                  ; sys_close
    syscall


exit:
    xor rcx, rcx
    mov cl, [dlugoscwyniku]

    ; zakładamy, że r9 ma wartość crc
    ; i cl zawiera liczbę bitów do wypisania
    
    mov rdx, rcx                ; ustaw rdx jako licznik pozostałych bitów
    mov rbx, rcx
    lea rdi, [output]           ; rdi wskazuje na bufor wyjściowy
    mov rcx, 64
    sub rcx, [dlugoscwyniku]
    
.next_bit:
    dec rbx                     ; zmniejsz licznik bitów
    mov rax, r9                 ; przenieś crc do rax
    shr rax, cl                 ; przesuń bity w prawo o wartość cl
    inc rcx
    and rax, 1                  ; wyizoluj najniższy bit
    add rax, '0'                ; zamień bit na znak '0' lub '1'
    mov [rdi + rbx], al         ; zapisz znak do bufora
    test rbx, rbx               ; sprawdź, czy rcx jest zerem
    jnz .next_bit               ; jeśli nie jest zerem, kontynuuj
    
    ; wywołanie sys_write, aby wypisać wynik na standardowe wyjście
    mov rax, 10
    mov [rdi + rdx], al
    mov rax, 1                  ; numer syscall dla sys_write
    mov rdi, 1                  ; file descriptor 1 - stdout
    lea rsi, [output]           ; bufor danych
    inc rdx
    mov rdx, rdx                ; liczba bajtów do wypisania (oryginalne rcx)
    syscall

    ; Zakończ program
    mov rax, 60                 ; sys_exit
    xor rdi, rdi                ; Kod wyjścia: 0
    syscall


error_exit:

    ; Zamknij plik, jeśli otwarty
    test rdi, rdi
    jz exit                     ; Plik nie został otwarty
    mov rax, 3                  ; sys_close
    syscall

    mov rax, 60                 ; sys_exit
    mov rdi, 1                  ; Kod wyjścia: 0
    syscall
