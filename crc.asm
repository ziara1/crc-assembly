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
    length resw 1           ; Przechowuje długość fragmentu (2 bajty)
    offset resd 1           ; Przechowuje przesunięcie fragmentu (4 bajty)

    output resb 65 ; maksymalnie 64 bity + null terminator




section .data
    crcTable times 256 dq 0         ; Tablica 256 elementów 64-bitowych wypełniona zerami
    err_msg db 'Error', 10     ; Komunikat o błędzie zakończony nowym wierszem
    err_msg_len equ $ - err_msg
    dlugoscwyniku db 0


section .text
    global _start

_start:
    ; Wczytaj parametry programu
    mov rdi, [rsp+8]           ; argv[0] (nazwa programu)
    mov rsi, [rsp+16]          ; argv[1] (nazwa pliku)
    mov rdx, [rsp+24]          ; argv[2] (wielomian CRC)

    ; Sprawdź, czy wszystkie argumenty są podane
    ; moze test rsp 3 jeszcze nwm
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
    mov rbx, 64
    mov [dlugoscwyniku], cl
    sub rbx, rcx
    mov cl, bl
    shl rax, cl
    mov [crc_poly_num], rax    ; Zapisz wynik do zmiennej



crcInit:
    mov rcx, [rel crc_poly_num]   ; POLYNOMIAL
    mov r8, 0x8000000000000000

    ; Dla każdego możliwego dividend (0-255)
    xor rdi, rdi                ; dividend = 0

crcLoop:
    mov eax, edi                ; eax = dividend (tylko dolne 32 bity nas interesują)
    shl rax, 56                 ; remainder = dividend << (WIDTH - 8)
    mov rbx, rax                ; Przenieś remainder do rbx
    mov rdx, 8

    ; Dla każdego bitu (od 8 do 0)
bitLoop:
    test rbx, r8            ; Sprawdź, czy TOPBIT jest ustawiony
    jz noDivision

    ; Jeśli TOPBIT jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1
    xor rbx, rcx                ; remainder = remainder ^ POLYNOMIAL
    jmp nextBit

noDivision:
    ; Jeśli TOPBIT nie jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1

nextBit:
    sub dl, 1                   ; bit--
    jnz bitLoop

    ; Przechowaj wynik w crcTable
    mov [crcTable + rdi*8], rbx ; crcTable[dividend] = remainder

    ; Następny dividend
    inc edi                     ; dividend++
    cmp edi, 256                ; Sprawdź, czy dividend < 256
    jl crcLoop


    ; Otwórz plik
    mov rax, 2                 ; sys_open
    mov rdi, rsi               ; Nazwa pliku
    mov rsi, 0                 ; Oflag: O_RDONLY
    syscall
    test rax, rax
    js error_exit
    mov rdi, rax               ; Zapisz deskryptor pliku

    xor r9, r9

read_fragment:
    ; Wczytaj 2 bajty długości fragmentu
    mov rax, 0                 ; sys_read
    mov rsi, length            ; Bufor na długość fragmentu (2 bajty)
    mov rdx, 2                 ; Wczytaj 2 bajty
    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd
    test rax, rax
    jz close_and_exit          ; Koniec pliku

    ; Przetwórz długość fragmentu (little-endian)
    movzx r8, word [length]    ; Przechowuje długość fragmentu w r8


process_data:
    ; Sprawdź, czy długość fragmentu jest większa niż bufor

    cmp r8, 4096
    jbe .read_data             ; Jeśli długość <= 4096, wczytaj dane
    ; Wczytuj dane w partiach po 4096 bajtów
.read_chunk:

    mov rax, 0                 ; sys_read
    mov rsi, buffer            ; Bufor 4096 bajtowy
    mov rdx, 4096              ; Wczytaj 4096 bajtów
    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd
    test rax, rax
    jz close_and_exit          ; Koniec pliku

    xor rbx, rbx
.crc_loop1:

    cmp rbx, rax
    jge .done1
    movzx r10, byte [rsi + rbx]   ; Załaduj message[byte] do r10, rozszerzając do 64 bitów
    mov r11, r9            ; Przenieś remainder do r11
    shr r11, 56            ; Przesuń remainder w prawo o (64 - 8) bitów
    xor r10, r11           ; data = message[byte] ^ (remainder >> 56)

    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; Załaduj crcTable[data] do r11, rozszerzając do 64 bitów
    shl r9, 8              ; Przesuń remainder w lewo o 8 bitów
    xor r9, r11            ; remainder = crcTable[data] ^ (remainder << 8)

    inc rbx                ; Zwiększ indeks (byte)
    jmp .crc_loop1          ; Przejdź do następnego bajtu

.done1:
    sub r8, rax                ; Zmniejsz pozostałą długość fragmentu
    jmp process_data           ; Kontynuuj przetwarzanie danych

.read_data:
    mov rax, 0                 ; sys_read
    mov rsi, buffer            ; Bufor 4096 bajtowy
    mov rdx, r8                ; Wczytaj pozostałe dane fragmentu

    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd
    test rax, rax
    jz close_and_exit          ; Koniec pliku

    xor rbx, rbx
.crc_loop2:
    cmp rbx, rax
    jge .done2
    movzx r10, byte [rsi + rbx]   ; Załaduj message[byte] do r10, rozszerzając do 64 bitów
    mov r11, r9            ; Przenieś remainder do r11
    shr r11, 56            ; Przesuń remainder w prawo o (64 - 8) bitów
    xor r10, r11           ; data = message[byte] ^ (remainder >> 56)


    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; Załaduj crcTable[data] do r11, rozszerzając do 64 bitów

    shl r9, 8              ; Przesuń remainder w lewo o 8 bitów
    xor r9, r11            ; remainder = crcTable[data] ^ (remainder << 8)

    inc rbx                ; Zwiększ indeks (byte)

    jmp .crc_loop2          ; Przejdź do następnego bajtu

.done2:


    ; Wczytaj 4 bajty przesunięcia fragmentu
    mov rax, 0                 ; sys_read
    mov rsi, offset            ; Bufor na przesunięcie fragmentu (4 bajty)
    mov rdx, 4                 ; Wczytaj 4 bajty
    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd
    test rax, rax
    jz close_and_exit          ; Koniec pliku

; Przetwórz przesunięcie fragmentu (little-endian, signed)
    movsxd rax, dword [offset] ; Przenosi i rozszerza znak 32-bitowego offsetu do 64-bitowego rejestru

    ; Sprawdź, czy przesunięcie wskazuje na początek fragmentu
   movzx r8, word [length]    ; Przechowuje długość fragmentu w r8
   add r8, 6
   neg r8
   sub r8, rax
   test r8, r8
   jz close_and_exit

    ; Przesuń wskaźnik pliku o wartość przesunięcia
    mov rdx, rax               ; Przesunięcie
    mov rax, 8                 ; sys_lseek
    mov rsi, rdx               ; Przesunięcie
    mov rdx, 1                 ; SEEK_CUR
    syscall
    test rax, rax
    js close_and_exit          ; Wystąpił błąd

    jmp read_fragment          ; Wczytaj kolejny fragment





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
    xor rcx, rcx
    mov cl, [dlugoscwyniku]
    ;shr r9, cl



    ; zakładamy, że r9 ma wartość crc
    ; i cl zawiera liczbę bitów do wypisania
    
    ;mov rcx, cl         ; przenieś wartość cl do rcx (liczba bitów)
    mov rdx, rcx        ; ustaw rdx jako licznik pozostałych bitów
    mov rbx, rcx
    lea rdi, [output]   ; rdi wskazuje na bufor wyjściowy
    mov rcx, 64
    sub rcx, [dlugoscwyniku]
    
.next_bit:
    dec rbx             ; zmniejsz licznik bitów
    mov rax, r9        ; przenieś crc do rax
    shr rax, cl         ; przesuń bity w prawo o wartość cl
    inc rcx
    and rax, 1          ; wyizoluj najniższy bit
    add rax, '0'        ; zamień bit na znak '0' lub '1'
    mov [rdi + rbx], al ; zapisz znak do bufora
    test rbx, rbx       ; sprawdź, czy rcx jest zerem
    jnz .next_bit       ; jeśli nie jest zerem, kontynuuj
    
    ; wywołanie sys_write, aby wypisać wynik na standardowe wyjście
  mov rax, 10
  mov [rdi + rdx], al
    mov rax, 1          ; numer syscall dla sys_write
    mov rdi, 1          ; file descriptor 1 - stdout
    lea rsi, [output]   ; bufor danych
  inc rdx
    mov rdx, rdx        ; liczba bajtów do wypisania (oryginalne rcx)
    syscall



    ; Zakończ program
    mov rax, 60                ; sys_exit
    xor rdi, rdi               ; Kod wyjścia: 0
    syscall




    ; jesli jest 1 bajt to go zapamietaj
    ; zrobic etykiete nowy fragment
    ; a w etykiecie process_buffer sprawdzac rejestry, czy np 
    ; zostalo do przetworzenia przesuniecie, czy dlugosc, czy bajty
    ; zrobic rejestry na poczatek fragmentu
    ; na checksum, na dlugosc fragmentu i na przesuniecie
    ; tym od poczatku fragmentu wyznaczamy odkad iterowac
    ; i mamy iterator zeby isc az do konca fragmentu
    ; jesli sie nie miescie fragment to zobaczmy czy poczatek - dl + 4 > 4096 
    ; czy cos takiego albo policzyc to zeby wiedziec ile trzeba bajtow wczytac jeszcze
    ; a jesli nie miesci sie dlugosc to po prostu zapamietujemy 1 bajt i 2 i na luzie
    ; rejestry rax rdx  rsi  r8 r9 r10  rbx 

    ; dobra sposob karola
    ; wczytuje 2 bajty do bufora
    ; wczytuje teraz na maksa az nie wczytam wszystkich
    ; czyli jakas zmienna ktora liczy ile jeszcze zostalo 
    ; na koniec wczytuje ofset i o tyle przesuwam
    ; czyli rejestr na 
    ; adres poczatku
    ; dlugosc
    ; ofset ale to juz mozna ktorys uzyc
    ; ile zostalo do konca
    ; iterator

    ; zmienia sie rcx i r11
    
    ; rbx r10 r9
    ;    print "", rbx
