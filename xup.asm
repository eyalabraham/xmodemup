;************************************************************************;
;*                                                                      *;
;*      Copyright JK microsystems 1998  -  All Rights Reserved          *;
;*                                                                      *;
;*      This software is NOT shareware, freeware, or public domain.     *;
;*      It is the property of JK microsystems.                          *;
;*                                                                      *;
;*      Customers of JK microsystems may modify the source code         *; 
;*      and/or distribute the binary image of this software without     *;
;*      additional costs provided it is run only on hardware            *;
;*      manufactured by JK microsystems.  All other use is expressly    *;
;*      prohibited.                                                     *;
;*                                                                      *;
;*      Update Log                                                      *;
;*                                                                      *;
;*      Version Date    Comments                        Progammer       *;
;*      ------- ------- ------------------------------- ----------      *;
;*      3.0     7-12-13 Rewrite for NASM compilation                    *;
;*                       and adaptation to new-bios                     *;
;*                       PC/XT hardware environement    Eyal            *;
;*      2.0     9-30-98 Major rewrite of v1.1 -                         *;
;*                       Runs on both V-25 and 386Ex                    *;
;*                       Hooks for Multi I/O board                      *;
;*                       Does CRC error detection                       *;
;*                       Properly handles full disk                     *;
;*                       Works with all known hosts                     *;
;*                       Uses command tail file argument                *;
;*                       Timeouts fixed                 jds             *;
;*                                                                      *;
;************************************************************************;
;
%include        "iodef.asm"            ; io port definitions for new-bios PC/XT
%include        "memdef.asm"           ; new-bios memory locations
;
%idefine offset                        ; allow NASM to ignore the MASM 'offset' directive
%idefine ptr                           ; allow NASM to ignore the MASM 'ptr' directive
;
        org     100h
;
start:
        mov     ax,cs                   ; point ds at our segment
        mov     ds,ax                   ; 
        mov     es,ax                   ; and es
        mov     dx,offset crlf          ; print a cr and lf
        mov     ah,9h
        int     21h                     
        mov     ch,0                    ; zero hi byte of cx
        mov     si,80h                  ; point to cmd line length in psp
        mov     cl,[si]                 ; get it in cl
        cmp     cl,0                    ; test for zero length filename
        jne     name_present            ; jump around if non-zero length
        mov     dx,offset help          ; point to help message
        mov     ah,9h                   ; tell dos
        int     21h                     ; to print it
        mov     ax,4C00h                ; tell dos
        int     21h                     ; to terminate
name_present:
        inc     si                      ; point to start of string
        mov     di,offset filename      ; point to buffer
        cld                             ; string moves increment
        rep     movsb                   ; move the string into buffer
        mov     [di],byte ptr 0         ; terminate string with null
        mov     di,offset filename      ; point di at start of filename
skip_space:
        inc     di                      ; skip past first space
        cmp     [di],byte ptr (' ')     ; test for more leading spaces
        je      skip_space              ; if another, increment past it
        mov     dx,di                   ; done, point dx to first char
        mov     ax,3C00h                ; Create File function
        mov     cx,0                    ; no special attributes
        int     21h                     ; do it
        jnc     good_open               ; jmp around if good
        mov     dx,offset open_error    ; point to error message
        mov     ah,9h                   ; tell dos
        int     21h                     ; to print it
        mov     ax,4C00h                ; then terminate
        int     21h
good_open:
        mov     [handle],ax             ; save the file handle
        mov     dx,offset ready         ; tell user we are ready
        mov     ah,9h   
        int     21h                     ; let dos do it

        call    serial_init             ; determine the serial port and initialize it if necessary
;@@- from here on, UART interrupts are diabled on my PC/XT, remember to restore them !!
;
clear_uart:
        call    get_status              ; clear the serial channel
        jnc     set_timeout             ; of any garbage chars
        call    get_char
        jmp     clear_uart

set_timeout:
        mov     cx,30                   ; 30 times through, 1 second per time
send_c:
        mov     bp,18                   ; set the timer to 18 = 1 second
        mov     al,('C')                ; poll the host for a crc packet
        call    put_char
wait_1_sec:                             ; wait 1 second for reply
        call    get_char
        jc      check_header            ; got it, continue on
        loop    send_c                  ; try again up to CX times

        mov     dx,offset timeout       ; point to error message
        mov     ah,9h                   ; tell dos
        int     21h                     ; to print it
        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; then terminate
        int     21h

check_header:
        cmp     al,3                    ; was it control-c
        jne     get_1st_packet          ; no, continue
;
        mov     dx,offset abort_message ; point to error message
        mov     ah,9h                   ; tell dos
        int     21h                     ; to print it
        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; then terminate
        int     21h

get_1st_packet:
        mov     dh,30                   ; 30 retrys
        mov     bp,54                   ; 3 second timeout - increase if 
                                        ; accessing floppies cause errors
        mov     dl,1                    ; starting sequence number
        mov     bx,0                    ; zero the crc
        mov     di,offset packet_buffer ; data buffer
        mov     cx,128                  ; data area byte count

soh_loop:
        cmp     al,soh                  ; is it soh?
        je      get_1st_sequence        ; yes, get first seqence number
        call    get_char                ; no, may be garbage, try again
        jc      soh_loop                ; no timeout, got char
        jmp     send_c                  ; timed out, try sending another c

        mov     dl,1                    ; packet number
get_packet:
        mov     dh,5                    ; 5 retrys
retry_packet:
        mov     bp,54                   ; 3 second timeout - increase if 
                                        ; accessing floppies cause errors
        mov     bx,0                    ; zero the crc
        mov     di,offset packet_buffer ; data buffer
        mov     cx,128                  ; data area byte count

        call    get_char                ; get soh
        jnc     packet_error            ; timed out, try again
        cmp     al,soh                  ; start of header?
        je      get_1st_sequence        ; yes, get first packet
        cmp     al,eot                  ; end of transmission?
        je      last_packet             ; yes, finish up and leave
        jmp     packet_error            ; unknown, try again

get_1st_sequence:
        call    get_char                ; get sequence number
        jnc     packet_error            ; we timed out
        cmp     al,dl                   ; sequence number didn't match
        jne     packet_error            ; try again

        call    get_char                ; get complemented sequence number
        jnc     packet_error            ; timed out
        not     al                      ; complement our sequence number
        cmp     al,dl                   ; do they match?
        jne     packet_error            ; no, retry

fill_buffer:
        call    get_char                ; get char
        jnc     packet_error            ; timed out
        mov     [di],al                 ; store it
        call    crc                     ; and run it through crc engine

        inc     di                      ; bump buffer pointer
        loop    fill_buffer             ; loop back until buffer is full

        mov     al,0                    ; flush crc engine with
        call    crc                     ; 2 more bytes of zeros
        mov     al,0
        call    crc

        call    get_char                ; get crc hi byte
        mov     ah,al
        call    get_char                ; get crc lo byte

        cmp     ah,bh                   ; check crc hi byte
        jne     packet_error
        cmp     al,bl
        jne     packet_error

        inc     dl                      ; increment the sequence number

        jmp     write_buffer            ; write the buffer to disk

last_packet:
        mov     al,ack                  ; send an ack
        call    put_char
                
        mov     bx,[handle]             ; close the file
        mov     ah,3Eh
        int     21h

        cmp     [full],byte 1           ; did we run out of disk space?
        je      full_disk               ; yes, go to error message

        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; no, back to dos prompt
        int     21h     

packet_error:
        dec     dh                      ; decrement retrys
        jz      too_many_errors         ; all out of retrys
line_clear:
        mov     bp,18                   ; gobble chars until line goes
        call    get_char                ; dead for 1 second
        jc      line_clear

        mov     al,nak                  ; nak the block
        call    put_char
        jmp     retry_packet            ; and try to receive it again

too_many_errors:
        mov     dx,offset rx_error      ; point to error message
        mov     ah,9h                   ; tell dos
        int     21h                     ; to print it
        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; then terminate
        int     21h

write_buffer:
        push    dx
        cmp     [full],byte 1           ; disk full?
        je      dont_write              ; yes, skip disk write 

        mov     dx,offset packet_buffer ; no, point to data buffer
        mov     ah,40h                  ; file write
        mov     bx,[handle]
        mov     cx,128                  ; 128 bytes
        int     21h                     ; do it

        jc      disk_error              ; dos says there was an error

        cmp     ax,128                  ; did we write the whole buffer?
        je      dont_write              ; yes, continue on

        mov     [full],byte ptr 1       ; no, flag it and continue

dont_write:
        mov     al,ack                  ; acknowledge the block
        call    put_char

        pop     dx                      ; restore the sequence number
        jmp     get_packet              ; and get the next packet
                
full_disk:
        mov     dx,offset disk_fullm    ; tell user disk is full
        mov     ah,9                    ; tell dos
        int     21h                     ; to print it

        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; and leave
        int     21h

disk_error:
        pop     dx                      ; balance stack
        mov     dx,offset disk_errorm   ; tell user we got a disk error 
        mov     ah,9                    ; tell dos
        int     21h                     ; to print it
        
        call    pc_xt_restore_int       ; restore UART interrupts on my PC/XT
        mov     ax,4C00h                ; and leave
        int     21h

;-----------------------------------------------------------------------------
;
;       Checks the timer tick count at [40:6C] and decrements BP
;       if it has changed from the value in [last_tick].
;       
tick:
        push    ax                      ; make some room to work
        push    ds
        push    di
        mov     ax,40h                  ; point to bios seg
        mov     ds,ax
        mov     di,timer
        mov     al,[di]
        pop     di
        pop     ds                      ; restore DS
        mov     ah,[last_tick]          ; get the last tick
        cmp     al,ah                   ; are they the same?
        je      tick_done               ; yes, leave
        mov     [last_tick],al
        dec     bp                      ; decrement the timeout value
tick_done:
        pop     ax
        ret
        
;-----------------------------------------------------------------------------
;
;       Run the byte in AL through the CRC engine
;
;       CRC is accumulated in BX, 2 additional bytes of zero's must be
;       run through the engine at the end in order to properly 
;       form the result.
;
;       The code in this routine was copied from either a public domain
;       or 'fair use' source and copywrite is not claimed for it.
;
crc:
        push    cx                      
        mov     cx,8                    ; number of bits in byte
crc_loop_1:
        rcl     al,1                    ; shift the data byte
        rcl     bx,1                    ; shift the mask
        jnc     crc_loop_2              ; skip the xor if 0
        xor     bx,1021h                ; do the xor
crc_loop_2:
        loop    crc_loop_1
        pop     cx
        ret
        
;-----------------------------------------------------------------------------
;
;       get_char waits for an incoming char while decrementing BP with each
;       timer tick.  If BP goes to zero before a char is received, get_char 
;       returns with carry clear. If a char is received before BP goes to 
;       zero, carry is set and the char is returned in AL.  
;
;       get_char also dispatches to the proper serial handler based on the
;       value of io_byte.
;
;       io_byte = 0  PC COM1 / console - implemented
;       io_byte = 1  PC COM2 - future
;       io_byte = 2  PC COM3 - future
;       io_byte = 3  PC COM4 - future
;       io_byte = 4  Multi I/O UART #1 - future
;       io_byte = 5  Multi I/O UART #2 - future
;       io_byte = 6  Multi I/O UART #3 - future
;       io_byte = 7  Multi I/O UART #4 - future
;       io_byte = 8  V-25 J4 / console - implemented
;       io_byte = 9  V-25 J6 - future
;       io_byte = aa  PC/XT new-bios hardware system @@- added to support my HW config and BIOS
;
get_char:
        call    get_status              ; get the status
        jc      got_char                ; move on if available
        call    tick                    ; update the tick count
        cmp     bp,0                    ; timed out?
        jne     get_char                ; no, continue to wait for char
        clc                             ; yes, clear carry
        ret                             ; and leave
;
got_char:
        call    get_char_dispatch       ; get the char
        stc                             ; set carry
        ret                             ; and return
;
;-----  get Rx status from UART
;
get_status:
        cmp     [io_byte], byte sign    ; check is this is my PC/XT
        je      .try_pc_xt              ;  yes, get status
        cmp     [io_byte],byte ptr 0    ;  no, try other systems
        jne     .try_v25
        call    pc_status
        ret
.try_pc_xt:                             ; get Rx status from my PC/XT
        call    pc_xt_status
        ret
.try_v25:
        call    V25_status
        ret
;
;-----  get charcter from UART
;
get_char_dispatch:
        cmp     [io_byte],byte sign     ; is this my PC/XT?
        je      .try_pc_xt              ;  yes, get character
        cmp     [io_byte],byte ptr 0    ;  no, try other systems
        jne     .try_v25
        call    pc_in
        ret
.try_pc_xt:
        call    pc_xt_in
        ret
.try_v25:
        call    V25_in
        ret

put_char:
        cmp     [io_byte], byte sign    ; is this my PC/XT?
        je      .try_pc_xt              ;  yes, put character
        cmp     [io_byte],byte ptr 0    ;  no, try other systems
        jne     .try_v25
        call    pc_out
        ret
.try_pc_xt:
        call    pc_xt_out
        ret
.try_v25:
        call    V25_out
        ret

;-----------------------------------------------------------------------------
;
;       mt PC/XT Serial In - wait for data and return it in AL
;
pc_xt_in:
        push    dx
        mov     dx,RBR
        in      al,dx
        pop     dx
        ret

;-----------------------------------------------------------------------------
;
;       V25 Serial In - wait for data and return it in AL
;
V25_in:                                 ; wait for and return char
        push    si
        push    ds                      ; save data seg
        push    ax
        mov     ax,0F000h               ; point to V-25 I/O segment
        mov     ds,ax
        pop     ax
        mov     si,sric0                ; point to serial rx interrupt reg
        mov     [si],byte ptr 40h       ; data available, clear interrupt
        mov     si,rxb0                 ; point to rx reg
        mov     al,[si]                 ; and get data in al
        pop     ds                      ; restore registers
        pop     si
        ret                             ; and leave

;-----------------------------------------------------------------------------
;
;       PC Serial In - wait for data and return it in AL
;
pc_in:                                  ; wait for and return char
        push    dx
        mov     dx,[com_port_base]
        in      al,dx
        pop     dx
        ret
        
;-----------------------------------------------------------------------------
;
;       my PC/XT Serial Status - set carry if data is available
;
pc_xt_status:                           ; set carry if char avail
        push    ax
        push    dx
        mov     dx,LSR
        in      al,dx                   ; get UART line status
        sar     al,1                    ; shift Rx status into CT.f
        pop     dx
        pop     ax
        ret                             ; and leave

;-----------------------------------------------------------------------------
;
;       V25 Serial Status - set carry if data is available      
;
V25_status:                             ; set carry if char avail
        push    si
        push    ds                      ; save data seg
        push    ax
        mov     ax,0F000h               ; point to V-25 I/O segment
        mov     ds,ax
        pop     ax
        mov     si,sric0                ; point to serial rx interrupt reg
        mov     al,[si]                 ; get it
        sal     al,1                    ; get data available bit in carry
        pop     ds                      ; carry set if data available
        pop     si                      ; restore registers
        ret                             ; and leave

;-----------------------------------------------------------------------------
;
;       PC Serial Status - set carry if data is available       
;
pc_status:                              ; set carry if char avail
        push    dx
        mov     dx,[com_port_base]
        add     dx,5
        in      al,dx
        rcr     al,1
        pop     dx
        ret

;-----------------------------------------------------------------------------
;
;       my PC/XT Serial Send - Send the char in AL and wait until done
;
pc_xt_out:
        push        ax
        push        dx
        mov         dx,LSR
        mov         ah,al               ; save AL
pc_xt_wait_out:
        in          al,dx               ; read LSR
        and         al,00100000b        ; check if transmit hold reg is empty
        jz          pc_xt_wait_out      ; loop if not empty
        mov         dx,THR
        mov         al,ah               ; restore AL
        out         dx,al               ; output to serial console
        pop         dx
        pop         ax
        ret

;-----------------------------------------------------------------------------
;
;       V25 Serial Send - Send the char in AL and wait until done
;
V25_out:
        push    si
        push    ds                      ; save data seg
        push    ax
        mov     ax,0F000h               ; point to V-25 I/O segment
        mov     ds,ax
        pop     ax                      ; get char
        push    ax
        mov     si,txb0                 ; point to tx data register
        mov     [si],al                 ; send the data
        mov     si,stic0                ; point to serial tx interrupt reg
V25_out_wait:
        mov     al,[si]                 ; get it
        sal     al,1                    ; get 'ok to send' bit in carry
        jnc     V25_out_wait            ; and loop if not ok to send
        mov     [si],byte ptr 40h       ; if ok, clear interrupt
        pop     ax
        pop     ds                      ; restore the registers
        pop     si
        ret                             ; and return

;-----------------------------------------------------------------------------
;
;       PC Serial Send - Send the char in AL and wait until done
;
pc_out:
        push    dx
        push    ax
        mov     dx,[com_port_base]
        add     dx,5
PC_out_wait:
        in      al,dx
        and     al,20h
        jz      PC_out_wait     
        mov     dx,[com_port_base]
        pop     ax
        out     dx,al
        pop     dx
        ret

;-----------------------------------------------------------------------------
;
;       Set the I/O byte according to the port used
;
;       First we determine whether we are on a 386Ex or V-25.  On a 386, 
;       bit 4 of the PSW is always low.  On a V-25, bit 4 can be harmlessly
;       set or cleared by the user.
;
;       If the processor is a 386Ex, we set the I/O byte to zero, if a V-25,
;       we set it to 8.
;
serial_init:
;@@- determine if running on a new-bios system by reading year from date signiture of ROM
        push    ds
        mov     ax,ROMSEG
        mov     ds,ax
        mov     ax,[ds:(RELDATE+6)]     ; get date's year-digits
        pop     ds
        cmp     ax,3331h                ; are the 'newbios' characters '13' present in the release year?
        jne     not_new_bios            ; continue if not 'newbios'
        mov     [io_byte],byte sign     ; set signiture
;
;-----  setup UART
;
        mov     dx,IER
        mov     al,0
        out     dx,al                   ; disable UART's Rx interrupt generation
;
;-----  exit serial_init
;
        jmp     done

not_new_bios:
        pushf                           ; put the psw on the stack
        pop     ax                      ; pop it into ax
        or      al,00001000b            ; set bit 3
        push    ax                      ; put ax back on stack
        popf                            ; and pop it into psw

        pushf                           ; put the psw on the stack
        pop     ax                      ; pop it into ax
        and     al,00001000b            ; clear all but bit 3
        jz      I386                    ; yes, must be 386

        mov     [io_byte],byte 8        ; no, V-25
        ret

I386:
        mov     [io_byte],byte 0        ; 386 com2
        mov     ax,com2_base            ; use com1
        mov     word ptr [com_port_base],ax     

done:
        call    print_system            ; print system type
        ret

;-----------------------------------------------------------------------------
;
;       if running on my PC/XT then use this routine to restore
;       UART intterupts that were disabled in 'serial_init'
;
pc_xt_restore_int:
        cmp     [io_byte],byte sign    ; is this my PC/XT?
        jne     no_int_restore          ;  no, nothing to do here
        mov     dx,IER
        mov     al,INTRINIT
        out     dx,al                   ; enable UART's Rx interrupt generation
no_int_restore:
        ret

;-----------------------------------------------------------------------------
;
;       print out system type for user verification
;       call this routine only after 'serial_init'
;
print_system:
        push    ax
        push    dx
        cmp     [io_byte],byte sign    ; is this my PC/XT?
        jne     .try_v25
        mov     dx,note_my_pc_xt
        jmp     .print_note
.try_v25:
        cmp     [io_byte],byte 8       ; is this a v25?
        jne     .try_386
        mov     dx,note_v25
        jmp     .print_note
.try_386:
        mov     dx,note_386
;
.print_note:
        mov     ah,9h
        int     21h
        pop     dx
        pop     ax
        ret

;-----------------------------------------------------------------------------
;
;               Data and buffer area
;
help:           db      "Upload file with X-MODEM Protocol",0Dh,0Ah
                db      "Usage:  xup <file_name>",0Dh,0Ah
                db      "Version 3.0 adapted from JK microsystems Flashlite V25 and 386Ex",0Dh,0Ah
                db      "Build: ", __DATE__, " ", __TIME__
crlf:           db      0Dh,0Ah,"$"

note_my_pc_xt:  db      "system: PC/XT",0Dh,0Ah,"$"
note_v25:       db      "system: V25",0Dh,0Ah,"$"
note_386:       db      "system: i386",0Dh,0Ah,"$"

open_error:     db      "Error opening file",0Dh,0Ah,"$"

write_error:    db      "Error writing file",0Dh,0Ah,"$"

rx_error:       db      0Dh,0Ah,0Dh,0Ah,"Too many errors - transfer aborted",0Dh,0Ah,"$"

disk_errorm:    db      0Dh,0Ah,0Dh,0Ah,"A disk error occured",0Dh,0Ah,"$"

disk_fullm:     db      0Dh,0Ah,0Dh,0Ah,"Disk Full","$"

timeout:        db      0Dh,0Ah,0Dh,0Ah,"Timed out waiting for host to send",0Dh,0Ah,"$"

abort_message:  db      0Dh,0Ah,0Dh,0Ah,"Transfer aborted by user",0Dh,0Ah,"$"

ready:          db      "Ready, start X-modem upload (CNTL-C to abort)...",0Dh,0Ah,"$"

full:           db      0
io_byte:        db      0
last_tick:      db      0
handle:         dw      0
com_port_base:  dw      0

filename:       times   20h   db   20h  ; buffer for filename
packet_buffer:  times   80h   db   0    ; buffer for packet

com1_base:      equ     word ptr 3F8h
com2_base:      equ     word ptr 2F8h
com3_base:      equ     word ptr 3E8h
com4_base:      equ     word ptr 2E8h

soh:    equ     byte ptr        01h     ; start of header
eot:    equ     byte ptr        04h     ; end of text
ack:    equ     byte ptr        06h     ; acknowledged
nak:    equ     byte ptr        15h     ; not acknowledged

timer:  equ     word ptr        0006Ch  ; offset of timer tick increment
stic0:  equ     word ptr        0FF6Eh  ; offset tx0 interrupt reg
sric0:  equ     word ptr        0FF6Dh  ; offset rx0 interrupt reg
txb0:   equ     word ptr        0FF62h  ; offset tx0 data reg
rxb0:   equ     word ptr        0FF60h  ; offset rx0 data reg

sign:   equ     0aah                    ; 'newbios' signiture for serial io handling
;
;-----  end of source code
;
