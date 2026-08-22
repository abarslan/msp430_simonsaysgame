;-------------------------------------------------------------------------------
; MSP430 Assembler Code Template for use with TI Code Composer Studio
;
;
;-------------------------------------------------------------------------------
            .cdecls C,LIST,"msp430.h"       ; Include device header file

         	.data
level        .byte   0                       ; current game level
current_step .byte   0                       ; current step in pattern
temp_var     .byte   0                       ; temporary variable
mute_flag    .byte   0                       ; 0=sound on, 1=sound off, mute flag works only in idle mode
random_seed  .word   19                      ; LFSR seed, works with time passed in idle mode

; increase pattern (step) length at each new level (length = level + 1)
pattern     .byte   0, 0, 0, 0, 0           ; max level 4 = 5 steps
max_level   .equ    4                       ; max level 4
;-------------------------------------------------------------------------------
            .def    RESET                   ; Export program entry-point to
                                            ; make it known to linker.
;-------------------------------------------------------------------------------
            .text                           ; Assemble into program memory
            .retain                         ; Override ELF conditional linking
                                            ; and retain current section
            .retainrefs                     ; Additionally retain any sections
                                            ; that have references to current
                                            ; section
;-------------------------------------------------------------------------------
RESET
			mov.w   #__STACK_END,SP         ; Initialize stackpointer
StopWDT     mov.w   #WDTPW|WDTHOLD,&WDTCTL  ; Stop watchdog timer
;-------------------------------------------------------------------------------
                                            ; Main loop here
;-------------------------------------------------------------------------------
_main:
            call    #init_gpio              ; pin initializations
            clr.b   &level                  ; clear level variable

;-------------------------------------------------------------------------------
; Pre-Game Idle Sequence (Waiting for Start)  
; leds goes turn on and off  0->1->2->3->2->1->0
; press button 1 (p1.1) to start.
;-------------------------------------------------------------------------------
idle_state:
            mov.b   #00000001b, r5          ; start with led 0 (p2.0)
            clr.b   r4                      ; direction: 0=left, 1=right

idle_loop:
            ; increment random seed with every loop for waiting
            inc.w   &random_seed

            ; update game leds for animation but keep win LED as it is
            mov.b   &P2OUT, r6              ; read current P2 state
            and.b   #00010000b, r6          ; keep only win LED bit (bit 4)
            bis.b   r5, r6                  ; combine with animation LED
            mov.b   r6, &P2OUT              ; write back to P2

            ; play sound based on LED position
            call    #idle_music_note

            ; check for start button (p1.1)
            bit.b   #00000010b, &P1IN       ; check p1.1 button
            jz      start_game_trigger      ; jump if 0 means start button is pressed, start the game

            ; check for mute flag (flag changes if p1.2 + p1.3 pressed together)
            mov.b   &P1IN, r6
            and.b   #00001100b, r6          ; mask p1.2 and p1.3
            jnz     no_mute_toggle          ; if both button is not pressed then skip
            call    #toggle_mute            ; toggle mute state
            call    #delay_debounce         ; debounce
            call    #delay_debounce         ; debounce

no_mute_toggle:
            ; delay for idle animation speed
            mov.w   #40000, r15             ; reduced delay, sound also have delay
            call    #delay_cycles

            ; move led with a direction for animation
            tst.b   r4                      ; check direction
            jnz     move_right              ; if r4=1, go right

move_left:
            rla.b   r5                      ; shift left
            cmp.b   #00001000b, r5          ; if not reached p2.3 , continue
            jne     idle_loop               
            mov.b   #1, r4                  ; if reached switch direction to right
            jmp     idle_loop

move_right:
            rra.b   r5                      ; shift right
            cmp.b   #00000001b, r5          ; if not reached p2.0 , continue
            jne     idle_loop               
            mov.b   #0, r4                  ; if reached switch direction to left
            jmp     idle_loop

start_game_trigger:
            ; turn off all leds (game leds + win led)
            mov.b   #00000000b, &P2OUT

            call    #delay_debounce         ; debounce
            mov.b   #1, &level              ; set level to 1 
            call    #delay_2sec             ; first wait before level

;-------------------------------------------------------------------------------
; play level function 
;-------------------------------------------------------------------------------
play_level:
            call    #generate_pattern       ; generate new random pattern for this level
            call    #show_pattern           ; display pattern
            call    #get_user_input         ; wait for users input 

            ; SUCCESS: if we return here level passed, turn on onboard green led for a short time

            bis.b   #01000000b, &P1OUT      ; turn on p1.6
            call    #delay_500ms            ; delay green LED flash
            bic.b   #01000000b, &P1OUT      ; turn off p1.6
            call    #beep_success           ; play success sound

            ; check win condition
            cmp.b   #max_level, &level      ; check if max level reached
            jeq     game_win                ; if done, go to win

            ; next level setup
            inc.b   &level                  ; proceed to next level
            call    #delay_500ms            ; 500ms pause before next level
            call    #delay_500ms            ; 500ms pause before next level
            jmp     play_level              ; jump to next level

;-------------------------------------------------------------------------------
; show_pattern
; displays the level sequence with 500ms delay
;-------------------------------------------------------------------------------
show_pattern:
            clr.b   r6                      ; r6 = loop counter
            mov.w   #pattern, r7            ; r7 = pointer to pattern array
            mov.b   &level, r5              ; r5 = target count, max length
            inc.b   r5                      ; target = level_index + 1

show_loop:
            cmp.b   r5, r6                  ; check if all steps shown
            jge     show_done               ; if counter = pattern length jump to done

            ; get led index from pattern
            mov.b   @r7+, r8                ; load whole byte and increment pointer
            push    r8                      ; use as LED index (0-3) for beep sound

            call    #get_led_mask           ; convert index to bitmask

            mov.b   r8, &P2OUT              ; turn led on
            pop     r8                      ; restore LED index
            call    #beep_for_led           ; play tone for this LED
            call    #delay_500ms            ; hold on for 0.5s

            mov.b   #00000000b, &P2OUT      ; turn led off
            mov.w   #15000, r15             ; short gap between blinks
            call    #delay_cycles

            inc.b   r6                      ; proceed to next step
            jmp     show_loop

show_done:
            ret

;-------------------------------------------------------------------------------
; get_user_input
; waits for user button interactions and compares game inputs with correct patterns 
;-------------------------------------------------------------------------------
get_user_input:
            clr.b   r6                      ; r6 = input counter
            mov.w   #pattern, r7            ; r7 = pointer to pattern array
            mov.b   &level, r5              ; r5 = target count, max length
            inc.b   r5                      ; target = level_index + 1

input_loop:
            cmp.b   r5, r6                  ; check if all inputs are done
            jge     input_success           ; if done without any error and reached here, return success

            ; wait for any button press
wait_press:
            mov.b   &P1IN, r9               ; read port 1
            and.b   #00011110b, r9          ; mask buttons (p1.1-p1.4)
            cmp.b   #00011110b, r9          ; check if all high (not pressed)
            jeq     wait_press              ; wait if nothing pressed

            call    #delay_debounce         ; simple debounce for healthier button interaction

            ; to see which button was pressed
            mov.b   &P1IN, r9               ; read again for stable reading of button 

            ; check button 0 (p1.1)
            bit.b   #00000010b, r9
            jz      btn_0_pressed
            ; check button 1 (p1.2)
            bit.b   #00000100b, r9
            jz      btn_1_pressed
            ; check button 2 (p1.3)
            bit.b   #00001000b, r9
            jz      btn_2_pressed
            ; check button 3 (p1.4)
            bit.b   #00010000b, r9
            jz      btn_3_pressed

            jmp     wait_press              ; if input not detected, go back

btn_0_pressed:
            mov.b   #0, r10                 ; user pressed 0
            jmp     check_match
btn_1_pressed:
            mov.b   #1, r10                 ; user pressed 1
            jmp     check_match
btn_2_pressed:
            mov.b   #2, r10                 ; user pressed 2
            jmp     check_match
btn_3_pressed:
            mov.b   #3, r10                 ; user pressed 3

check_match:
            ; visual + audio feedback for button press
            mov.b   r10, r8                 ; r10 has LED index (0-3)
            push    r8                      ; save index for beep
            call    #get_led_mask
            mov.b   r8, &P2OUT              ; turn on pressed led to let user track
            pop     r8                      ; restore index
            call    #beep_for_led           ; play tone for this led

            ; wait for release
wait_release:
            mov.b   &P1IN, r9
            and.b   #00011110b, r9
            cmp.b   #00011110b, r9
            jne     wait_release

            mov.b   #00000000b, &P2OUT      ; turn off all led

            ; compare with expected pattern value
            mov.b   @r7+, r11               ; load the expected value
            cmp.b   r10, r11
            jne     game_over               ; if not equal, then failed game over

            inc.b   r6                      ; proceed to next input
            jmp     input_loop

input_success:
            ret                             ; return to play_level

;-------------------------------------------------------------------------------
; game_over 
; red on board led on (p1.0), all game leds blink for 1 sec
;-------------------------------------------------------------------------------
game_over:
            bis.b   #00000001b, &P1OUT      ; turn on onboard red (p1.0)

            ; blink all 4 game leds for 2 seconds with buzzer each blink
            mov.w   #2, r11                 ; use r11 for loop 
fail_blink:
            mov.b   #00001111b, &P2OUT      ; all game leds on
            call    #beep_fail              ; buzz sound on each blink
            call    #delay_500ms
            mov.b   #00000000b, &P2OUT      ; all game leds off
            call    #beep_fail              ; buzzer sound on each blink
            call    #delay_500ms
            dec.w   r11
            jnz     fail_blink

            bic.b   #00000001b, &P1OUT      ; turn off red led
            jmp     idle_state              ; auto return to idle sequence

;-------------------------------------------------------------------------------
; game_win state
; external win led on (p2.4) and victory melody plays
;-------------------------------------------------------------------------------
game_win:
            bis.b   #00010000b, &P2OUT      ; turn on win led (p2.4)
            call    #beep_win               ; play victory melody

            ; for a clean break wait for all buttons to be released before returning to idle 
wait_release_win:
            mov.b   &P1IN, r9
            and.b   #00011110b, r9          ; mask buttons p1.1-p1.4
            cmp.b   #00011110b, r9          ; all released?
            jne     wait_release_win
            call    #delay_debounce         ; debounce 

            jmp     idle_state              ; return to idle

;-------------------------------------------------------------------------------
; generate_pattern random
; fills pattern array with random values using LFSR
; lvl1=2 step, lvl2:3 step...
;-------------------------------------------------------------------------------
generate_pattern:
            ;save registers for further use
            push    r6
            push    r7
            push    r8

            mov.w   #pattern, r7            ; r7 = pointer to pattern array
            mov.b   &level, r6              ; r6 = loop counter
            inc.b   r6                      ; increment to reach pattern length = level + 1

gen_loop:
            ; get next random number
            call    #lfsr_next              ; result in r8 (0-65535)
            and.b   #00000011b, r8          ; mask to 0-3

            mov.b   r8, 0(r7)               ; store in pattern
            inc.w   r7                      ; next position
            dec.b   r6
            jnz     gen_loop

            pop     r8
            pop     r7
            pop     r6
            ret

;-------------------------------------------------------------------------------
; lfsr_next
; 16-bit LFSR pseudo-random number generator
; polynomial: x^16 + x^14 + x^13 + x^11 + 1 (maximum = 65535)
; output: r8 = next random value
;-------------------------------------------------------------------------------
lfsr_next:
            mov.w   &random_seed, r8          ; load current seed

            ;LFSR: check LSB, shift right, XOR with polynomial if LSB was 1
            bit.w   #1, r8                  ; test LSB (feedback bit)
            rrc.w   r8                      ; shift right through carry (clears MSB)
            jnc     lfsr_store              ; if carry=0 (LSB was 0), skip XOR

            ;if reached here LSB is 1: XOR with polynomial 0xB400
            xor.w   #0xB400, r8

lfsr_store:
            ; ensure non-zero, because LFSR locks up at zero
            tst.w   r8
            jnz     lfsr_done
            mov.w   #19, r8                 ; reseed if zero

lfsr_done:
            mov.w   r8, &random_seed        ; store new seed
            ret

;-------------------------------------------------------------------------------
; get_led_mask
; input: r8 (0-3) -> output: r8 (bitmask)
;-------------------------------------------------------------------------------
get_led_mask:
            cmp.b   #0, r8
            jz      mask_0
            cmp.b   #1, r8
            jz      mask_1
            cmp.b   #2, r8
            jz      mask_2
            ;if none of above jumped then r8 must be 3 mask directly
            mov.b   #00001000b, r8      
            ret
mask_0:     mov.b   #00000001b, r8
            ret
mask_1:     mov.b   #00000010b, r8
            ret
mask_2:     mov.b   #00000100b, r8
            ret

;-------------------------------------------------------------------------------
;init_gpio: initialization for input and output ports
;-------------------------------------------------------------------------------
init_gpio:
            ; configure to calibrated 1MHz for consistent timing every run
            mov.b   &CALBC1_1MHZ, &BCSCTL1  ; set range
            mov.b   &CALDCO_1MHZ, &DCOCTL   ; set DCO step + modulation

            ; port 1 setup (game buttons + onboard leds)
            mov.b   #01000001b, &P1DIR      ; p1.0, p1.6 out, others in
            mov.b   #00011110b, &P1REN      ; enable resistors on p1.1-1.4
            mov.b   #00011110b, &P1OUT      ; pull-up resistors (inputs high)

            ; port 2 (game leds + external win led + buzzer)
            mov.b   #00111111b, &P2DIR      ; p2.0-p2.5 out (p2.5 = buzzer)
            mov.b   #00000000b, &P2OUT      ; all off
            ret

;-------------------------------------------------------------------------------
; delay_cycles
; basic delay unit
;-------------------------------------------------------------------------------
delay_cycles:
            tst.w   r15
            jz      d_exit
d_loop:     dec.w   r15
            jnz     d_loop
d_exit:     ret

;-------------------------------------------------------------------------------
; delay_500ms
; creates a 0.5s pause
;-------------------------------------------------------------------------------
delay_500ms:
            mov.w   #5, r14                 ; run inner loop 5 times
delay500_outer:
            mov.w   #33000, r15             ; 100ms per loop
            call    #delay_cycles
            dec.w   r14
            jnz     delay500_outer
            ret

;-------------------------------------------------------------------------------
; delay_2sec and delay_debounce
;-------------------------------------------------------------------------------
delay_debounce:
            mov.w   #2000, r15
            jmp     delay_cycles

delay_2sec:
            mov.w   #20, r14                ; 20 * 100ms = 2 sec
delay2000_outer:
            mov.w   #33000, r15
            call    #delay_cycles
            dec.w   r14
            jnz     delay2000_outer
            ret

;-------------------------------------------------------------------------------
; buzzer tone generation
; play_tone: r13 = half-period delay, r12 = number of cycles
; controls mute flag, skips playing if muted
;-------------------------------------------------------------------------------
play_tone:
            ; check if mute_flag skip all sound to mute
            tst.b   &mute_flag
            jnz     tone_mute_flag          ; if mute_flag, jump and return to called line

            push    r15
tone_loop:
            xor.b   #00100000b, &P2OUT      ; toggle buzzer at P2.5 
            mov.w   r13, r15                ; load half-period delay
tone_delay:
            dec.w   r15
            jnz     tone_delay
            dec.w   r12                     ; decrement cycle count
            jnz     tone_loop
            bic.b   #00100000b, &P2OUT      ; ensure buzzer off
            pop     r15
tone_mute_flag:
            ret

;-------------------------------------------------------------------------------
; predefined sounds for buzzer 
; smaller r13 = higher frequency = higher tone 
;-------------------------------------------------------------------------------
; beep for LED 0 (lowest tone ~2kHz)
beep_led0:
            mov.w   #80, r13                ; half-period (smaller = higher pitch)
            mov.w   #400, r12               ; duration cycles
            call    #play_tone
            ret

; beep for LED 1 (~2.5kHz)
beep_led1:
            mov.w   #65, r13
            mov.w   #500, r12
            call    #play_tone
            ret

; beep for LED 2 (~3kHz)
beep_led2:
            mov.w   #55, r13
            mov.w   #600, r12
            call    #play_tone
            ret

; beep for LED 3 
beep_led3:
            mov.w   #47, r13
            mov.w   #700, r12
            call    #play_tone
            ret

; success beep, ascending melody
beep_success:
			call	#delay_500ms
            mov.w   #70, r13
            mov.w   #500, r12
            call    #play_tone
            mov.w   #50, r13
            mov.w   #600, r12
            call    #play_tone
            ret

; fail beep 
beep_fail:
            mov.w   #110, r13
            mov.w   #800, r12
            call    #play_tone
            ret

; win melody, longer ascending 
beep_win:
            mov.w   #80, r13
            mov.w   #400, r12
            call    #play_tone
            mov.w   #65, r13
            mov.w   #400, r12
            call    #play_tone
            mov.w   #55, r13
            mov.w   #400, r12
            call    #play_tone
            mov.w   #45, r13
            mov.w   #800, r12
            call    #play_tone
            ret

; beep based on that moment current LED index in r8 (0-3)
beep_for_led:
            cmp.b   #0, r8
            jeq     beep_led0
            cmp.b   #1, r8
            jeq     beep_led1
            cmp.b   #2, r8
            jeq     beep_led2
            jmp     beep_led3


            
            ; toggles the mute_flag flag between 0 and 1
toggle_mute:
            xor.b   #1, &mute_flag            
            ret

;-------------------------------------------------------------------------------
; idle mode background music notes following LED animation (r5 = mask)
; (r5 = mask) C-D-E-F-E-D-C-D-E-F...
;-------------------------------------------------------------------------------
idle_music_note:
            push    r12
            push    r13
            ; convert LED mask to note
            cmp.b   #00000001b, r5          
            jeq     idle_note0
            cmp.b   #00000010b, r5          
            jeq     idle_note1
            cmp.b   #00000100b, r5          
            jeq     idle_note2
            cmp.b   #00001000b, r5         
            jeq     idle_note3
            jmp     idle_note_done

idle_note0:                                 ; C note
            mov.w   #95, r13
            mov.w   #100, r12
            jmp     idle_play
idle_note1:                                 ; D note
            mov.w   #85, r13
            mov.w   #110, r12
            jmp     idle_play
idle_note2:                                 ; E note
            mov.w   #75, r13
            mov.w   #120, r12
            jmp     idle_play
idle_note3:                                 ; F note
            mov.w   #70, r13
            mov.w   #130, r12

idle_play:
            call    #play_tone

idle_note_done:
            pop     r13
            pop     r12
            ret

;-------------------------------------------------------------------------------
;           Stack Pointer definition
;-------------------------------------------------------------------------------
            .global __STACK_END
            .sect 	.stack

;-------------------------------------------------------------------------------
;           Interrupt Vectors
;-------------------------------------------------------------------------------
            .sect   ".reset"                ; MSP430 RESET Vector
            .short  RESET
			.end
