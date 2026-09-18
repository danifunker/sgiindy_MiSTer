| Register | PROM | kernel | Xsgi | IRIS GL | OpenGL |
|---|---|---|---|---|---|
| DRAWMODE1 | W7 | W15; R1 | W82 | W53 (GO 5); R1 | W43 |
| DRAWMODE0 | W9 (GO 3) | W10 (GO 3); R1 | W93 (GO 1) | W65 (GO 6) | W111 (GO 1) |
| LSMODE | W2 | W2; R1 | W5 | W32 | W8 |
| LSPATTERN | W2 | W2; R1 | W8 (GO 2) | W35 (GO 2) | W8 |
| LSPATSAVE | W2 | W2; R1 | W1 | W1 |  |
| ZPATTERN | W38 (GO 36) | W44 (GO 42); R1 | W154 (GO 153) | W62 (GO 59) | W39 (GO 37) |
| COLORBACK | W2 | W2; R1 | W6 |  |  |
| COLORVRAM | W2 | W3; R1 | W11 | W2 | W11 |
| ALPHAREF |  | W1; R1 |  | W1 | W1 |
| SMASK0X | W2 | W2; R1 | W1 | W2 | W1 |
| SMASK0Y | W2 | W2; R1 | W1 | W2 | W1 |
| SETUP |  |  | W10 | W23 | W12 |
| STEPZ |  |  |  | W2 (GO 2) |  |
| LSRESTORE |  |  |  | W31 | W7 |
| LSSAVE |  |  |  | W4 | W4 |
| XSTART | R1 | W1; R2 |  |  |  |
| YSTART |  | W1; R1 |  |  | W43 |
| XEND |  | W1; R1 |  |  |  |
| YEND |  | W1; R1 |  |  | W32 |
| XSAVE | W2 | W2; R1 | W1 |  |  |
| XYMOVE | W3 (GO 1) | W2; R1 | W5 (GO 4) | W1 | W2 (GO 2) |
| BRESD | W2 | W2; R1 | W3 |  |  |
| BRESS1 | W2 | W2; R1 | W1 |  |  |
| BRESOCTINC1 | W3 | W7; R1 | W31 | W11 |  |
| BRESRNDINC2 | W2 | W2; R1 | W1 |  | W1 |
| BRESE1 | W2 | W2; R1 | W1 | W2 | W1 |
| BRESS2 | W2 | W2; R1 | W1 |  |  |
| AWEIGHT0 | W2 | W2; R1 | W1 | W1 | W1 |
| AWEIGHT1 | W2 | W2; R1 | W1 | W1 | W1 |
| XSTARTF |  |  |  | W32 (GO 4, swc1 20) | W16 (GO 3, swc1 14) |
| XSTARTF+YSTARTF |  |  |  | W12 (GO 6, sdc1 12) | W17 (GO 8, sdc1 17) |
| YSTARTF |  |  |  | W30 (GO 2, swc1 17) | W35 (GO 1, swc1 33) |
| XENDF |  |  |  | W29 (GO 4, swc1 23) | W12 (swc1 10) |
| XENDF+YENDF |  |  |  | W8 (GO 2, sdc1 8) | W11 (sdc1 11) |
| YENDF |  |  |  | W20 (GO 4, swc1 11) | W8 (GO 3, swc1 7) |
| XSTARTI | W1 | W1 |  | W6 | W6 |
| XSTARTI+XENDF1 |  |  |  | W11 (GO 4, sdc1 11) |  |
| XYSTARTI | W12 (GO 1) | W14 (GO 1) | W203 (GO 102) | W55 | W60 |
| XYSTARTI+XYENDI |  |  |  |  | W66 (GO 6, sdc1 66) |
| XYENDI | W10 (GO 5) | W13 (GO 5) | W154 (GO 64) | W28 | W45 (GO 18) |
| XSTARTENDI |  |  |  | W20 | W38 (GO 7) |
| COLORRED | W2 | W3; R1 | W1 | W72 (swc1 72) | W107 (GO 18, swc1 107) |
| COLORRED+COLORALPHA |  |  |  |  | W7 (GO 1, sdc1 7) |
| COLORALPHA | W2 | W2; R1 | W1 | W16 (swc1 16) | W46 (GO 2, swc1 46) |
| COLORGREEN | W1 | W2; R1 | W1 | W34 (swc1 34) | W59 (swc1 59) |
| COLORGREEN+COLORBLUE |  |  |  | W4 (sdc1 4) | W11 (GO 4, sdc1 11) |
| COLORBLUE | W1 | W2; R1 | W1 | W33 (GO 1, swc1 33) | W59 (GO 15, swc1 59) |
| SLOPERED |  | W2; R1 |  | W13 (swc1 13) | W24 (GO 2, swc1 24) |
| SLOPERED+SLOPEALPHA |  |  |  |  | W2 (sdc1 2) |
| SLOPEALPHA |  | W2; R1 |  | W4 (swc1 4) | W6 (swc1 6) |
| SLOPEGREEN |  | W2; R1 |  | W8 (swc1 8) | W14 (swc1 14) |
| SLOPEGREEN+SLOPEBLUE |  |  |  | W4 (sdc1 4) | W4 (GO 2, sdc1 4) |
| SLOPEBLUE |  | W2; R1 |  | W8 (swc1 8) | W14 (swc1 14) |
| WRMASK | W8 | W10; R1 | W51 | W3 | W3 |
| COLORI | W5 | W6 | W42 | W31 (GO 30) |  |
| COLORX |  |  |  | W1 (swc1 1) |  |
| HOSTRW0 | W1 (GO 1); R1 (GO 1) | W3 (GO 2); R5 (GO 4) | W104 (GO 104); R24 (GO 24) | W59 (GO 59); R76 (GO 76) | W101 (GO 96); R30 (GO 30) |
| HOSTRW0+HOSTRW1 |  |  |  | W4 (GO 4, sdc1 4) | W54 (GO 54, sdc1 54) |
| HOSTRW1 |  | W1; R1 | W2 | W1 | W6 (GO 4) |
| DCBMODE | W153; R1 | W219; R14 | W43; R3 |  |  |
| DCBDATA0 | W136 (sb 97, sh 9); R17 (lbu 12, lhu 5) | W155 (sb 104, sh 14); R43 (lbu 39, lhu 4) | W37 (sb 9, sh 10); R13 (lbu 12, lhu 1) |  |  |
| SMASK1X | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK1Y | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK2X | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK2Y | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK3X | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK3Y | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK4X | W1 | W2; R1 | W1 | R2 | R2 |
| SMASK4Y | W1 | W2; R1 | W1 | R2 | R2 |
| TOPSCAN | W2 | W2; R4 |  |  |  |
| XYWIN | W4; R1 | W4; R1 | W14 | R1 |  |
| CLIPMODE | W2 | W3; R1 | W21 | R2 | R2 |
| CONFIG | W3 | W7; R2 | W1; R1 | W1; R2 | W1; R1 |
| STATUS | R3 | R6 |  |  |  |
| USER_STATUS | R126 | R277 | R45 | R1 | R33 |
| DCBRESET | W1 | W2 |  |  |  |

Never accessed by any of the five: STALL0, XENDF1, SLOPERED1, DCBDATA1, STALL1
