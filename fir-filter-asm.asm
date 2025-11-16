    .section .text
    .globl fir_filter
fir_filter:
    addi sp, sp, -16
    sw    s0, 0(sp)
    sw    s1, 4(sp)
    sw    s2, 8(sp)
    sw    s3, 12(sp)

    mv    s0, a0       # s0 = x pointer
    mv    s1, a1       # s1 = y pointer
    mv    s2, a2       # s2 = num samples
    mv    s3, a3       # s3 = h pointer
    mv    t5, a4       # t5 = num taps

outer_loop:
    beqz  s2, done     # if samples = 0, exit
    addi  s2, s2, -1   # s2--

    # accumulator = 0
    li    t0, 0        # t0 = acc (lower 32)
    li    t1, 0        # t1 = unused (for 64-bit mult expansion)

    mv    t2, s0       # t2 = current x pointer
    mv    t3, s3       # t3 = current h pointer
    mv    t4, t5       # t4 = remaining taps

tap_loop:
    beqz  t4, write_output

    lw    t6, 0(t2)    # x value
    lw    t7, 0(t3)    # h value

    mul   t8, t6, t7   # multiply (rv32 has mul if M-extension)
    add   t0, t0, t8   # acc += x*h

    addi  t2, t2, 4    # next x
    addi  t3, t3, 4    # next h
    addi  t4, t4, -1   # taps--

    j     tap_loop

write_output:
    sw    t0, 0(s1)    # store y[n]
    addi  s1, s1, 4    # advance output

    addi  s0, s0, 4    # shift input pointer by 1 sample
    j     outer_loop

done:
    lw    s0, 0(sp)
    lw    s1, 4(sp)
    lw    s2, 8(sp)
    lw    s3, 12(sp)
    addi  sp, sp, 16
    ret
