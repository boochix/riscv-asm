    .section .data
    # --------- USER TUNABLE (change cutoff_hz only) ----------
    cutoff_hz:   .word  6000        # <<< change this to desired cutoff in Hz
    fs:          .word  48000       # sample rate (Hz)
    num_taps:    .word  101         # N = 101 taps (must be odd for symmetric linear-phase)

    # --------- Constants in Q31 / Q64 as needed ----------
    # TWO_PI_Q31 and PI_Q31 stored as 64-bit (they exceed 32-bit)
    .align 8
TWO_PI_Q31:    .quad 13493037705    # round(2*pi * 2^31)
PI_Q31:        .quad 6746518852     # round(pi * 2^31)
INV_PI_Q31:    .word  683565276     # round((1/pi) * 2^31)  (fits 32-bit)
HALF_Q31:      .word  1073741824    # 0.5 in Q31 (2^30)
ONE_Q31:       .word  2147483647    # 1.0 ~ 0x7FFFFFFF (Q31)
C2_SIN:        .word  -357913941    # -1/6  * 2^31 (Q31)
C4_SIN:        .word   17895697     #  1/120 * 2^31 (Q31)
C2_COS:        .word -1073741824    # -1/2 * 2^31 (Q31)
C4_COS:        .word   89478485     #  1/24 * 2^31 (Q31)

    .align 8
fir_taps:
    .space 404          # 101 * 4 bytes = 404 bytes (space to store taps)
    .align 8

# A place to store a simple delay buffer for filtering (101 samples)
delay_buf:
    .space 404

# --------- Text section ----------
    .section .text
    .globl  main
    .ent    main

# -----------------------------------------------------------------------------
# sin_poly: compute sin(x) where x is Q31 (radians). Accepts input in a0 (64-bit signed)
# Returns sin(x) in a0 (lower 32 bits contain Q31 result, sign-extended in 64-bit)
# Steps:
#  - Range reduce x to [-pi, pi] then to [-pi/2, pi/2] using TWO_PI_Q31, PI_Q31
#  - Use polynomial: sin(x) ≈ x * (1 + c2*x^2 + c4*x^4)
# -----------------------------------------------------------------------------
    .type sin_poly, @function
sin_poly:
    # a0: angle (signed 64-bit, Q31)
    # preserve callee-saved
    addi    sp, sp, -64
    sd      s0, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)
    sd      s4, 32(sp)
    sd      s5, 40(sp)
    sd      s6, 48(sp)

    mv      s0, a0            # s0 = angle

    # load TWO_PI_Q31 (64-bit)
    la      t0, TWO_PI_Q31
    ld      t1, 0(t0)         # t1 = TWO_PI_Q31
    # compute q = s0 / TWO_PI_Q31  (signed)
    # -> integer number of whole 2pi cycles
    # use div for signed division
    div     s1, s0, t1        # s1 = quotient
    mul     s2, s1, t1        # s2 = q * TWO_PI_Q31
    sub     s3, s0, s2        # s3 = remainder r in range (-2pi, 2pi)
    # now rem = s3. Bring rem into (-pi, pi]
    la      t2, PI_Q31
    ld      t3, 0(t2)         # t3 = PI_Q31
    blt     s3, zero, .Lpos_rem
    # s3 >= 0
    bgt     s3, t3, .Lrem_gt_pi
    j       .Lrem_after_check

.Lpos_rem:
    # s3 < 0
    add     t4, s3, zero
    # if s3 <= -PI, add TWO_PI to bring into (-pi, pi]
    neg     t5, t3
    blt     s3, negt3, .Ladd_two_pi_placeholder
    j       .Lrem_after_check

# Provide labels used above (asm requires we reference defined labels)
.Lrem_gt_pi:
    # s3 > PI_Q31, subtract TWO_PI
    sub     s3, s3, t1
    j       .Lrem_after_check

# (fallback) compute negt3 and add TWO_PI if less than -PI
.Ladd_two_pi_placeholder:
    # compute -PI: -t3 and compare
    neg     t6, t3
    blt     s3, t6, .Ladd_two_pi
    j       .Lrem_after_check

.Ladd_two_pi:
    add     s3, s3, t1
    j       .Lrem_after_check

.Lrem_after_check:
    # s3 now in (-pi, pi]
    # Now map to [-pi/2, pi/2] with sign handling:
    # if s3 > PI/2  => angle_small = PI - s3 ; sign = +1
    # if s3 < -PI/2 => angle_small = s3 + PI ; sign = -1 (and then make positive)
    # else angle_small = s3 ; sign = +1 (if s3 negative sign will be handled by final multiplication)
    la      t7, PI_Q31
    ld      t8, 0(t7)         # t8 = PI_Q31
    srai    t9, t8, 1         # t9 = PI/2 (Q31)
    # Compare s3 with PI/2
    blt     s3, t9, .Lcheck_neg_halfpi
    # s3 >= PI/2
    sub     s4, t8, s3        # s4 = PI - s3  (positive in [0, PI/2])
    li      s5, 1             # sign = +1
    mv      s6, s4            # angle_small = s4
    j       .Lpoly_entry

.Lcheck_neg_halfpi:
    # s3 < PI/2 ; check if s3 < -PI/2
    neg     t10, t9           # -PI/2
    blt     s3, t10, .Lneg_case
    # else s3 in [-pi/2, pi/2]
    mv      s6, s3            # angle_small = s3
    li      s5, 1             # sign = +1
    j       .Lpoly_entry

.Lneg_case:
    # s3 < -PI/2  => angle_small = s3 + PI ; sign = -1 ; angle_small in (0, PI/2]
    add     s4, s3, t8        # s3 + PI
    li      s5, -1            # sign = -1
    mv      s6, s4            # angle_small = s4

.Lpoly_entry:
    # Now s6 contains angle_small in Q31 (signed 64-bit), s5 is sign (+1 or -1)
    # Compute x2 = (s6*s6) >> 31  (Q31)
    mv      a0, s6
    slli    a1, a0, 0         # just move
    # x2 = (int64)s6 * s6 >>31
    mul     t11, s6, s6       # t11 = s6*s6 (lower 64 bits)
    srai    t12, t11, 31      # t12 = x2 (Q31, 64-bit)

    # x4 = (x2 * x2) >> 31
    mul     t13, t12, t12
    srai    t14, t13, 31      # t14 = x4 (Q31)

    # t1 = C2_SIN * x2 >>31
    la      t15, C2_SIN
    lw      t16, 0(t15)       # C2_SIN (32-bit)
    slli    t16, t16, 32
    srai    t16, t16, 32      # sign-extend to 64
    mul     t17, t16, t12     # t17 = c2 * x2 (64-bit)
    srai    t17, t17, 31

    # t2 = C4_SIN * x4 >>31
    la      t18, C4_SIN
    lw      t19, 0(t18)
    slli    t19, t19, 32
    srai    t19, t19, 32
    mul     t20, t19, t14
    srai    t20, t20, 31

    # sum = ONE_Q31 + t1 + t2
    la      t21, ONE_Q31
    lw      t22, 0(t21)       # 0x7FFFFFFF
    slli    t22, t22, 32
    srai    t22, t22, 32
    add     t23, t22, t17
    add     t23, t23, t20     # t23 is sum (Q31)

    # sin = (s6 * sum) >>31
    mul     t24, s6, t23
    srai    t24, t24, 31      # t24 is sin(angle_small) Q31 (signed 64-bit)

    # apply sign s5
    li      t25, 1
    beq     s5, t25, .Lsin_done
    neg     t24, t24

.Lsin_done:
    # return sin in a0 (64-bit sign-extended)
    mv      a0, t24

    # restore regs & return
    ld      s0, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    ld      s4, 32(sp)
    ld      s5, 40(sp)
    ld      s6, 48(sp)
    addi    sp, sp, 64
    ret

    .size sin_poly, .-sin_poly

# -----------------------------------------------------------------------------
# cos_poly: compute cos(x) using polynomial:
# cos(x) ≈ 1 + c2_cos*x^2 + c4_cos*x^4
# Input: a0 = angle Q31 (signed 64)
# Output: a0 = cos(x) Q31 (signed 64)
# Uses same range reduction as sin_poly but simpler (map to [-pi, pi] then [-pi/2, pi/2])
# -----------------------------------------------------------------------------
    .type cos_poly, @function
cos_poly:
    addi    sp, sp, -32
    sd      s0, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)

    mv      s0, a0
    la      t0, TWO_PI_Q31
    ld      t1, 0(t0)
    div     s1, s0, t1
    mul     s2, s1, t1
    sub     s3, s0, s2         # s3 = rem in (-2pi,2pi)
    la      t2, PI_Q31
    ld      t3, 0(t2)
    blt     s3, zero, .Cpos
    bgt     s3, t3, .Csub2pi
    j       .Cafter

.Cpos:
    neg     t4, t3
    blt     s3, t4, .Cadd2pi
    j       .Cafter

.Csub2pi:
    sub     s3, s3, t1
    j       .Cafter

.Cadd2pi:
    add     s3, s3, t1

.Cafter:
    # Now s3 in (-pi,pi]
    # reduce to [-pi/2, pi/2] (for small-angle poly)
    srai    t4, t3, 1          # pi/2
    blt     s3, t4, .Ccheckneg
    # s3 >= pi/2
    sub     s5, t3, s3         # s5 = pi - s3, but we need exact PI - s3: compute t3 is PI
    la      t5, PI_Q31
    ld      t6, 0(t5)
    sub     s6, t6, s3         # s6 = PI - s3
    mv      s3, s6
    # cos(pi - x) = -cos(x) ??? actually cos(pi - x) = -cos(x) so we need sign flip
    li      s7, -1
    j       .Cpoly

.Ccheckneg:
    neg     t7, t4
    blt     s3, t7, .Cnegcase
    li      s7, 1
    j       .Cpoly

.Cnegcase:
    # s3 < -pi/2: let s3 = s3 + PI ; cos(s3) = -cos(s3+PI) ??? careful
    la      t8, PI_Q31
    ld      t9, 0(t8)
    add     s3, s3, t9
    li      s7, -1

.Cpoly:
    # s3 now in [-pi/2, pi/2] ; s7 indicates sign flip if needed
    # compute x2 = s3*s3 >>31
    mul     t10, s3, s3
    srai    t11, t10, 31       # x2 Q31
    # x4 = x2*x2>>31
    mul     t12, t11, t11
    srai    t13, t12, 31       # x4 Q31

    # t1 = C2_COS * x2 >>31
    la      t14, C2_COS
    lw      t15, 0(t14)
    slli    t15, t15, 32
    srai    t15, t15, 32
    mul     t16, t15, t11
    srai    t16, t16, 31

    # t2 = C4_COS * x4 >>31
    la      t17, C4_COS
    lw      t18, 0(t17)
    slli    t18, t18, 32
    srai    t18, t18, 32
    mul     t19, t18, t13
    srai    t19, t19, 31

    # sum = ONE_Q31 + t1 + t2
    la      t20, ONE_Q31
    lw      t21, 0(t20)
    slli    t21, t21, 32
    srai    t21, t21, 32
    add     t22, t21, t16
    add     t22, t22, t19   # t22 is cos(x) Q31 (signed 64)

    # apply sign flip if s7 == -1
    li      t23, -1
    beq     s7, t23, .Cnegflip
    mv      a0, t22
    j       .Cdone

.Cnegflip:
    neg     t22, t22
    mv      a0, t22

.Cdone:
    ld      s0, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    addi    sp, sp, 32
    ret

    .size cos_poly, .-cos_poly

# -----------------------------------------------------------------------------
# generate_taps:
# Generate N FIR taps (Hann-windowed sinc) and store them into fir_taps (Q31)
# Uses:
#   cutoff_hz (word), fs (word), num_taps (word)
# -----------------------------------------------------------------------------
    .globl generate_taps
    .type generate_taps, @function
generate_taps:
    addi    sp, sp, -48
    sd      s0, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)
    sd      s4, 32(sp)

    # load parameters
    la      t0, cutoff_hz
    lw      t1, 0(t0)         # t1 = cutoff_hz (int)
    la      t2, fs
    lw      t3, 0(t2)         # t3 = fs
    la      t4, num_taps
    lw      t5, 0(t4)         # t5 = N (101)
    mv      s0, t1            # s0 = fc
    mv      s1, t3            # s1 = fs
    mv      s2, t5            # s2 = N

    # compute M = N - 1
    addi    s3, s2, -1        # s3 = M
    srai    s4, s3, 1         # s4 = M/2  (integer)
    # load TWO_PI_Q31
    la      t6, TWO_PI_Q31
    ld      t7, 0(t6)         # t7 = TWO_PI_Q31 (64-bit)

    # compute wc_q31 = (fc * TWO_PI_Q31) / fs
    # fc * t7 fits in 64-bit for our ranges
    mv      a0, s0
    slli    a1, a0, 0
    # extend fc to 64-bit signed
    slli    a2, a0, 32
    srai    a2, a2, 32
    mul     t8, a2, t7        # t8 = fc * TWO_PI_Q31 (64-bit)
    # divide by fs
    mv      a3, s1
    div     t9, t8, a3        # t9 = wc_q31 (64-bit, Q31)
    mv      s5, t9            # s5 = wc_q31

    # Prepare INV_PI_Q31 for later
    la      t10, INV_PI_Q31
    lw      t11, 0(t10)
    slli    t11, t11, 32
    srai    t11, t11, 32      # sign-extend to 64
    mv      s6, t11           # s6 = INV_PI_Q31 (64)

    # Prepare pointers
    la      t12, fir_taps
    mv      s7, t12           # s7 -> tap storage base

    # Loop n = 0 .. N-1
    li      t13, 0            # n = 0

.GenLoop:
    bge     t13, s2, .Gdone

    # k = n - M/2
    mv      t14, t13
    sub     t15, t14, s4      # t15 = k (signed 32)
    # sign-extend to 64-bit
    slli    t16, t15, 32
    srai    t16, t16, 32      # t16 = k (64)

    # if k == 0 -> h0 = (wc/PI) -> h0_q31 = (wc_q31 * INV_PI_Q31) >>31
    beqz    t16, .Compute_h0

    # general case:
    # angle = (wc_q31 * k) >> 31  (Q31)
    mul     t17, s5, t16      # t17 = wc_q31 * k  (64)
    srai    t18, t17, 31      # t18 = angle (Q31, 64)

    # call sin_poly(angle) ; returns sin(angle) in a0
    mv      a0, t18
    call    sin_poly
    mv      t19, a0           # sin(angle) Q31 (64)

    # prod = sin(angle) * INV_PI_Q31  (64 * 64 -> 128 ideally but values fit in 64)
    mul     t20, t19, s6      # t20 ~ Q62

    # temp = t20 / k  (signed division)
    div     t21, t20, t16     # t21 is (sin*INV_PI)/k  (still Q62)

    # h_q31 = t21 >> 31
    srai    t22, t21, 31      # t22 = h_ideal Q31

    j       .Compute_window_and_store

.Compute_h0:
    # h0 = (wc_q31 * INV_PI_Q31) >>31
    mul     t23, s5, s6       # t23 = wc * INV_PI (Q62)
    srai    t22, t23, 31      # t22 = h0 Q31

.Compute_window_and_store:
    # Compute Hann window:
    # w[n] = 0.5 - 0.5 * cos( 2*pi * n / M )
    # compute arg = (TWO_PI_Q31 * n) / M  (Q31)
    mul     t24, t7, t13      # t24 = TWO_PI_Q31 * n
    div     t25, t24, s3      # t25 = arg (Q31)
    # compute cos(arg) using cos_poly
    mv      a0, t25
    call    cos_poly
    mv      t26, a0           # cos_q31

    # w = HALF_Q31 - ((cos*HALF_Q31) >>31)
    la      t27, HALF_Q31
    lw      t28, 0(t27)
    slli    t28, t28, 32
    srai    t28, t28, 32      # t28 = HALF_Q31 (64)
    mul     t29, t26, t28     # t29 = cos * HALF (Q62)
    srai    t30, t29, 31      # t30 = (cos*HALF) >>31 -> Q31
    la      t31, HALF_Q31
    lw      t32, 0(t31)
    slli    t32, t32, 32
    srai    t32, t32, 32      # t32 = HALF_Q31
    sub     t33, t32, t30     # w_q31 = HALF - (cos*HALF)>>31

    # Multiply h_ideal (t22 Q31) by window w_q31 -> h_final = (t22 * t33) >>31
    slli    t34, t22, 0
    mul     t35, t22, t33     # Q62
    srai    t36, t35, 31      # Q31 final
    # store lower 32 bits of t36 into fir_taps[n]
    slli    t37, t13, 2       # offset = n*4
    add     t38, s7, t37
    sw      t36, 0(t38)

    addi    t13, t13, 1
    j       .GenLoop

.Gdone:
    ld      s0, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    ld      s4, 32(sp)
    addi    sp, sp, 48
    ret

    .size generate_taps, .-generate_taps

# -----------------------------------------------------------------------------
# fir_filter:
# Simple FIR filtering using the taps in fir_taps and delay_buf.
# Prototype (RISC-V calling):
#   a0 = pointer to input samples (32-bit Q31 array)
#   a1 = pointer to output samples (32-bit Q31 array)
#   a2 = num_samples
#   Assumes taps are in fir_taps and num_taps in data
# -----------------------------------------------------------------------------
    .globl fir_filter
    .type fir_filter, @function
fir_filter:
    addi    sp, sp, -32
    sd      s0, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)

    mv      s0, a0        # input ptr
    mv      s1, a1        # output ptr
    mv      s2, a2        # num samples

    la      s3, num_taps
    lw      t0, 0(s3)
    mv      s4, t0        # s4 = N taps

    la      t1, fir_taps

OuterSampleLoop:
    beqz    s2, Fdone
    # accum in 64-bit
    li      t2, 0
    mv      t3, zero
    # For simplicity perform direct convolution using input pointer offset by sample index 0..num_samples-1
    # We'll do: y[n] = sum_{k=0..N-1} x[n-k]*h[k] (assumes x[-] = 0 for negative indices)
    # For clarity, we assume input buffer contains enough previous samples (or you can call with appropriate pre-padding)
    li      t4, 0         # k = 0
ConvLoop:
    bge     t4, s4, ConvDone
    # load h[k]
    slli    t5, t4, 2
    add     t6, t1, t5
    lw      t7, 0(t6)
    # load x sample: x_ptr + offset?? Here we use s0 as pointer to current sample; so load x_ptr - k
    # For simplicity we assume input pointer points to the current sample location (caller responsibility)
    # load x = *(s0 - 4*k)
    sub     t8, s0, t5
    lw      t9, 0(t8)
    # multiply
    mul     t10, t9, t7
    add     t2, t2, t10
    addi    t4, t4, 1
    j       ConvLoop

ConvDone:
    # shift back to Q31
    srai    t11, t2, 31
    sw      t11, 0(s1)
    addi    s0, s0, 4
    addi    s1, s1, 4
    addi    s2, s2, -1
    j       OuterSampleLoop

Fdone:
    ld      s0, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    addi    sp, sp, 32
    ret

    .size fir_filter, .-fir_filter

# -----------------------------------------------------------------------------
# main: demonstration entry point
#  - calls generate_taps (computes taps into fir_taps)
#  - returns (on a bare board you can hook fir_filter to run)
# -----------------------------------------------------------------------------
main:
    addi    sp, sp, -16
    sd      ra, 0(sp)
    call    generate_taps

    # (In a real program you'd load samples and call fir_filter)
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

    .end main
