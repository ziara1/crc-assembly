section .bss
    buffer resb 4096            ; bufor o rozmiarze 4096 bajtów
    crc_poly resq 1             ; przekształcony wielomian CRC
    length resw 1               ; długość fragmentu (2 bajty)
    offset resd 1               ; przesunięcie fragmentu (4 bajty)
    output resb 65              ; wynik - maksymalnie 64 bity + null terminator

section .data
    crcTable times 256 dq 0     ; crc table 256 wartości w zależności od bajtu 
    dlugoscwyniku db 0          ; dlugosc ostatecznego wyniku

section .text
    global _start


_start:
    ; wczytuje parametry programu
    mov rdi, [rsp+8]            ; argv[0] (nazwa programu)
    mov rsi, [rsp+16]           ; argv[1] (nazwa pliku)
    mov rdx, [rsp+24]           ; argv[2] (wielomian CRC)

    ; sprawdza, czy wszystkie argumenty są podane
    test rsi, rsi
    jz .error_exit
    test rdx, rdx
    jz .error_exit

    ; zmiana stringa wielomianu na ciąg zero-jedynkowy
    xor rbx, rbx
    xor rax, rax
    mov rcx, 64                 ; maksymalnie 64 bity do przetworzenia
    xor r8, r8

.convert_loop:
    test rcx, rcx               ; bo wtedy minęły 64 pętle, czyli maks. długość
    jz .done                    

    mov bl, byte [rdx]          ; wczytuje bieżący znak ze wskaźnika rdx
    test bl, bl                 ; sprawdza czy znak nie jest null terminatorem
    jz .done                    ; jeśli jest, kończy pętlę

    cmp bl, '0'                 ; czy aktualny znak jest '0'
    je .is_zero
    cmp bl, '1'                 ; czy aktualny znak jest '1'
    je .is_one

    jmp .error_exit             ; jeśli znak nie jest '0', ani '1', to error

.is_zero:
    shl rax, 1                  ; przeswa rax w lewo (dodaje 0 na koniec)
    jmp .next_char

.is_one:
    shl rax, 1                  ; przesuwa rax w lewo o 1 bit
    or rax, 1                   ; ustawia najmłodszy bit na 1
    jmp .next_char

.next_char:
    inc r8
    inc rdx                     ; przejdź do następnego znaku
    dec rcx                     ; zmniejsz licznik
    jmp .convert_loop           ; powtórz pętlę

.done:
    mov [dlugoscwyniku], r8     ; zapisuje długość wielomianu
    shl rax, cl                 ; przesuwa wielomian na maksa w prawo
    mov [crc_poly], rax         ; zapisuje wielomian do zmiennej

.crcInit:
    mov rcx, [rel crc_poly]     ; wielomian crc
    mov r8, 0x8000000000000000  ; najbardziej znaczący bit

    ; dla każdego możliwego dzielnika (0-255) zapełnia crc lookup table
    xor rdi, rdi                ; dzielnik = 0

.crcLoop:
    mov eax, edi                ; eax = dzielnik, tylko dolne 32 bity są ważne
    shl rax, 56                 ; remainder = dzielnik << (WIDTH - 8)
    mov rbx, rax                ; przenieś remainder do rbx
    mov rdx, 8

    ; dla każdego bitu (od 8 do 0)
.bitLoop:
    test rbx, r8                ; sprawdź, czy najb. zn. bit jest ustawiony
    jz .noDivision

    ; jeśli najb. zn. bit jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1
    xor rbx, rcx                ; remainder = remainder ^ wielomian
    jmp .nextBit

.noDivision:
    ; jeśli najb. zn. bit nie jest ustawiony
    shl rbx, 1                  ; remainder = remainder << 1

.nextBit:
    sub dl, 1                   ; bit--
    jnz .bitLoop

    ; przechowuje wynik w crcTable
    mov [crcTable + rdi*8], rbx ; crcTable[dzielnik] = remainder
    inc edi                     ; dzielnik++
    cmp edi, 256                ; sprawdź, czy dzielnik < 256
    jl .crcLoop

    ; otwiera plik
    mov rax, 2                  ; sys_open
    mov rdi, rsi                ; nazwa pliku
    mov rsi, 0                  ; oflag: O_RDONLY
    syscall
    test rax, rax
    js .error_exit
    mov rdi, rax                ; zapisuje deskryptor pliku
    xor r9, r9

.read_fragment:
    ; wczytuje 2 bajty długości fragmentu
    mov rax, 0                  ; sys_read
    mov rsi, length             ; bufor na długość fragmentu (2 bajty)
    mov rdx, 2                  ; wczytuje 2 bajty
    syscall
    test rax, rax
    js .error_exit              ; wystąpił błąd
    test rax, rax
    jz .error_exit              ; koniec pliku
    movzx r8, word [length]     ; przechowuje długość fragmentu w r8

.process_data:
    ; sprawdza, czy długość fragmentu jest większa niż bufor
    cmp r8, 4096
    jbe .read_data              ; jeśli długość <= 4096, wczytaj dane
    ; wczytuje dane w partiach po 4096 bajtów
.read_chunk:

    mov rax, 0                  ; sys_read
    mov rsi, buffer             ; bufor 4096 bajtowy
    mov rdx, 4096               ; wczytaj 4096 bajtów
    syscall
    test rax, rax
    js .error_exit              ; wystąpił błąd
    test rax, rax
    jz .error_exit              ; koniec pliku

    xor rbx, rbx
.crc_loop1:
    ; przetworzenie "danych" danego fragmentu
    cmp rbx, rax
    jge .done1
    movzx r10, byte [rsi + rbx] ; ładuje message[byte] do r10, rozszerza do 64 bitów
    mov r11, r9                 ; przenosi remainder do r11
    shr r11, 56                 ; przesuwa remainder w prawo o (64 - 8) bitów
    xor r10, r11                ; data = message[byte] ^ (remainder >> 56)

    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; ładuje crcTable[data] do r11, rozszerzając do 64 bitów
    shl r9, 8                   ; przesuwa remainder w lewo o 8 bitów
    xor r9, r11                 ; remainder = crcTable[data] ^ (remainder << 8)
    inc rbx                     ; zwiększa indeks (byte)
    jmp .crc_loop1              ; przechodzi do następnego bajtu

.done1:
    sub r8, rax                 ; zmniejsza pozostałą długość fragmentu
    jmp .process_data           ; kontynuuje przetwarzanie danych

.read_data:
    mov rax, 0                  ; sys_read
    mov rsi, buffer             ; bufor 4096 bajtowy
    mov rdx, r8                 ; wczytuje pozostałe dane fragmentu

    syscall
    test rax, rax
    js .error_exit              ; wystąpił błąd
    test rax, rax
    jz .error_exit              ; koniec pliku

    xor rbx, rbx
.crc_loop2:
    ; przetworzenie ostatniej partii "danych" danego fragmentu
    cmp rbx, rax
    jge .done2
    movzx r10, byte [rsi + rbx] ; ładuje message[byte] do r10, rozszerza do 64 bitów
    mov r11, r9                 ; przenosi remainder do r11
    shr r11, 56                 ; przesuwa remainder w prawo o (64 - 8) bitów
    xor r10, r11                ; data = message[byte] ^ (remainder >> 56)

    ; remainder = crcTable[data] ^ (remainder << 8);
    mov r11, [crcTable + 8*r10] ; ładuje crcTable[data] do r11, rozszerza do 64 bitów
    shl r9, 8                   ; przesuwa remainder w lewo o 8 bitów
    xor r9, r11                 ; remainder = crcTable[data] ^ (remainder << 8)
    inc rbx                     ; zwiększa indeks (byte)
    jmp .crc_loop2              ; przechodzi do następnego bajtu

.done2:

    ; Wczytaj 4 bajty przesunięcia fragmentu
    mov rax, 0                  ; sys_read
    mov rsi, offset             ; bufor na przesunięcie fragmentu (4 bajty)
    mov rdx, 4                  ; wczytuje 4 bajty
    syscall
    test rax, rax
    js .error_exit              ; wystąpił błąd
    test rax, rax
    jz .error_exit              ; koniec pliku
    movsxd rax, dword [offset]  ; przenosi i rozszerza znak 32-bitowego offsetu do 64-bitowego rejestru

    ; sprawdza, czy przesunięcie wskazuje na początek fragmentu
    movzx r8, word [length]     ; przechowuje długość fragmentu w r8
    add r8, 6
    neg r8
    sub r8, rax
    test r8, r8
    jz .close_and_exit

    ; Przesuń wskaźnik pliku o wartość przesunięcia
    mov rdx, rax                ; przesunięcie
    mov rax, 8                  ; sys_lseek
    mov rsi, rdx                ; przesunięcie
    mov rdx, 1                  ; SEEK_CUR
    syscall
    test rax, rax
    js .error_exit              ; wystąpił błąd
    jmp .read_fragment          ; wczytuje kolejny fragment

.close_and_exit:
    ; Zamknij plik
    mov rax, 3                  ; sys_close
    syscall

.exit:
    xor rcx, rcx
    mov cl, [dlugoscwyniku]    
    mov rdx, rcx                ; ustawia rdx jako licznik pozostałych bitów
    mov rbx, rcx
    lea rdi, [output]           ; rdi wskazuje na bufor wyjściowy
    mov rcx, 64
    sub rcx, [dlugoscwyniku]
    
.next_bit:
    dec rbx                     ; zmniejsza licznik bitów
    mov rax, r9                 ; przenosi crc do rax
    shr rax, cl                 ; przesuwa bity w prawo o wartość cl
    inc rcx
    and rax, 1                  ; wyizoluj najniższy bit
    add rax, '0'                ; zamień bit na znak '0' lub '1'
    mov [rdi + rbx], al         ; zapisz znak do bufora
    test rbx, rbx               ; sprawdza, czy rcx jest zerem
    jnz .next_bit               ; jeśli nie jest zerem, kontynuuje
    
    ; wywołanie sys_write, aby wypisać wynik na standardowe wyjście
    mov rax, 10
    mov [rdi + rdx], al
    mov rax, 1                  ; numer syscall dla sys_write
    mov rdi, 1                  ; file descriptor 1 - stdout
    lea rsi, [output]           ; bufor danych
    inc rdx
    mov rdx, rdx                ; liczba bajtów do wypisania 
    syscall

    ; kończy program
    mov rax, 60                 ; sys_exit
    xor rdi, rdi                
    syscall

.error_exit:

    ; zamyka plik, jeśli otwarty
    mov rax, 3                  ; sys_close
    syscall

    mov rax, 60                 ; sys_exit
    mov rdi, 1                 
    syscall