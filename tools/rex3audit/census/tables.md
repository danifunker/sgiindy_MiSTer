### libGLcore.so: 1241 accesses, 190 functions
| DRAWMODE1 | W sw:43 | 23 | FastDrawPixels_0, FastReadPixels, ClearCI, ClearRGB, __glNptAntiAliasLineRGBA, ReadCI +17 |
| DRAWMODE0 | W sw:110, W sw GO:1 | 89 | __glNptColorOptTriangle, StoreCI, __glNptFillFastTriangle, StoreRGB, StoreRGBA, StoreRGBA2 +83 |
| LSMODE | W sw:8 | 7 | __glNptFlatFogLine, __glNptFlatLine, __glNptFlatRGBLine, __glNptFlatCILine, __glNptSmoothRGBLine, __glNptSmoothCILine +1 |
| LSPATTERN | W sw:8 | 7 | __glNptFlatFogLine, __glNptFlatLine, __glNptFlatRGBLine, __glNptFlatCILine, __glNptSmoothRGBLine, __glNptSmoothCILine +1 |
| ZPATTERN | W sw:2, W sw GO:37 | 21 | __glNptRenderBitmap, __glNptDepthLine, __glNptStoreStippledHWLine, __glNptStoreStippledLine, __glNptFlatCIStippledSpan, __glNptShadeCIStippledSpan +15 |
| COLORVRAM | W sw:11 | 10 | __glNptRect, ClearCI, __glNptDownloadCurrentColor, __glNptDownloadCurrentIndex, __glnptim_Indexf, __glnptim_FastColor3ub +4 |
| ALPHAREF | W sw:1 | 1 | __glNptEnableAlphaTest |
| SMASK0X | W sw:1 | 1 | ApplyScissor |
| SMASK0Y | W sw:1 | 1 | ApplyScissor |
| SETUP | W sw:12 | 10 | __glNptRenderBitmap, FastReadPixels, __glNptDepthLine, __glNptStoreStippledHWLine, __glNptStoreLine, __glNptStoreStippledLine +4 |
| LSRESTORE | W sw:7 | 4 | WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptFlatFogLine |
| LSSAVE | W sw:4 | 4 | WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptFlatFogLine |
| YSTART | W sw:43 | 15 | __glNptSmoothRGBZOptTriangle, __glNptSmoothRGBOptTriangle, __glNptSmoothCIOptTriangle, __glNptSmoothRGBZSubTriangle, __glNptFlatZSubTriangle, __glNptSmoothRGBAZSubTriangle +9 |
| YEND | W sw:32 | 12 | __glNptSmoothRGBZOptTriangle, __glNptSmoothRGBOptTriangle, __glNptSmoothCIOptTriangle, __glNptSmoothRGBZSubTriangle, __glNptFlatZSubTriangle, __glNptSmoothRGBAZSubTriangle +6 |
| XYMOVE | W sw GO:2 | 1 | FastCopyPixels_0 |
| BRESRNDINC2 | W sw:1 | 1 | MakeCurrent |
| BRESE1 | W sw:1 | 1 | __glNptAntiAliasLineRGB |
| AWEIGHT0 | W sw:1 | 1 | MakeCurrent |
| AWEIGHT1 | W sw:1 | 1 | MakeCurrent |
| XSTARTF | W sw:2, W swc1:11, W swc1 GO:3 | 12 | __glNptDepthLine, WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptAntiAliasLineRGB, __glNptStoreCIStippledSpan +6 |
| XSTARTF+YSTARTF | W sdc1:9, W sdc1 GO:8 | 15 | __glNptFlatLine, __glNptFlatFogLine, __glNptFlatRGBLine, __glNptFlatCILine, __glNptSmoothRGBLine, __glNptSmoothCILine +9 |
| YSTARTF | W sw:2, W swc1:32, W swc1 GO:1 | 31 | __glNptDepthLine, WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptAntiAliasLineRGB, ReturnRGBSpan +25 |
| XENDF | W sw:2, W swc1:10 | 8 | __glNptDepthLine, WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptAntiAliasLineRGB, __glNptStoreCIStippledSpan +2 |
| XENDF+YENDF | W sdc1:11 | 10 | __glNptFlatLine, __glNptFlatRGBLine, __glNptFlatCILine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptFlatFogLine +4 |
| YENDF | W sw:1, W swc1:4, W swc1 GO:3 | 5 | WideFlatLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptAntiAliasLineRGB, __glNptDepthLine |
| XSTARTI | W sw:6 | 3 | __glNptTexDepthRGBASpan_uLESS_REPLACE_asm, __glNptTexDepthRGBASpan_sLESS_REPLACE_asm, __glNptTexRGBASpan_REPLACE_asm |
| XYSTARTI | W sw:60 | 46 | FastReadPixels, StoreCI, FastDrawPixels_0, FastDrawPixels_1, StoreRGB, StoreRGBA +40 |
| XYSTARTI+XYENDI | W sdc1:60, W sdc1 GO:6 | 33 | __glNptFlatCIFzSpan_asm, __glNptFlatRGBFzSpan_asm, __glNptShadeCIFzSpan_asm, __glNptShadeRGBFzSpan_asm, __glNptFlatDepthCIFzSpan_sLESS_asm, __glNptFlatDepthCIFzSpan_uLESS_asm +27 |
| XYENDI | W sw:27, W sw GO:18 | 39 | FastReadPixels, FastDrawPixels_0, FastDrawPixels_1, __glNptTexDepthRGBAFzSpan_REPLACE, __glNptTexDepthFzSpan_MODULATE, __glNptRenderBitmap +33 |
| XSTARTENDI | W sw:31, W sw GO:7 | 38 | ReturnRGBSpan, ReadRGBSpan, ReadRGBPackedSpan, __glNptFlatCISpan, __glNptFlatCIStippledSpan, __glNptShadeCISpan +32 |
| COLORRED | W swc1:89, W swc1 GO:18 | 89 | __glNptAntiAliasLineRGB, __glNptDepthLine, __glNptSmoothRGBLine, __glNptSmoothCILine, __glNptShadeCIFzSpan_asm, __glNptShadeDepthCIFzSpan_sLESS_asm +83 |
| COLORRED+COLORALPHA | W sdc1:6, W sdc1 GO:1 | 7 | __glNptFlatRGBLine, __glNptFlatFogLine, __glNptRasterFlatRGB, __glNptStoreLine, __glNptStoreStippledLine, __glNptRenderPoint_RGBA +1 |
| COLORALPHA | W swc1:44, W swc1 GO:2 | 42 | __glNptDepthLine, __glNptSmoothRGBLine, __glNptFlatRGBAZTriangle, __glNptFlatRGBATriangle, __glNptTexRGBFzSpan_REPLACE_asm, __glNptTexDepthRGBFzSpan_sLESS_REPLACE_asm +36 |
| COLORGREEN | W swc1:59 | 54 | __glNptAntiAliasLineRGB, __glNptDepthLine, ReturnRGBSpan, __glNptFlatRGBZTriangle, __glNptFlatRGBAZTriangle, __glNptFlatRGBTriangle +48 |
| COLORGREEN+COLORBLUE | W sdc1:7, W sdc1 GO:4 | 8 | __glNptSmoothRGBLine, __glNptFlatFogLine, __glNptFlatRGBLine, __glNptRasterFlatRGB, __glNptStoreLine, __glNptStoreStippledLine +2 |
| COLORBLUE | W swc1:44, W swc1 GO:15 | 54 | __glNptAntiAliasLineRGB, __glNptDepthLine, ReturnRGBSpan, __glNptFlatRGBZTriangle, __glNptFlatRGBAZTriangle, __glNptFlatRGBTriangle +48 |
| SLOPERED | W swc1:22, W swc1 GO:2 | 21 | __glNptAntiAliasLineRGB, __glNptFillFastTriangle, __glNptSmoothCILine, __glNptSmoothRGBZTriangle, __glNptSmoothRGBAZTriangle, __glNptSmoothCIZTriangle +15 |
| SLOPERED+SLOPEALPHA | W sdc1:2 | 2 | __glNptFlatFogLine, __glNptRasterSmoothRGB |
| SLOPEALPHA | W swc1:6 | 6 | __glNptSmoothRGBAZTriangle, __glNptSmoothRGBATriangle, __glNptFillFastTriangle, __glNptDepthLine, __glNptSmoothRGBLine, __glNptFastPathProcessSpan |
| SLOPEGREEN | W swc1:14 | 13 | __glNptAntiAliasLineRGB, __glNptSmoothRGBZTriangle, __glNptSmoothRGBAZTriangle, __glNptSmoothRGBTriangle, __glNptSmoothRGBATriangle, __glNptSmoothRGBZOptTriangle +7 |
| SLOPEGREEN+SLOPEBLUE | W sdc1:2, W sdc1 GO:2 | 3 | __glNptSmoothRGBLine, __glNptFlatFogLine, __glNptRasterSmoothRGB |
| SLOPEBLUE | W swc1:14 | 13 | __glNptAntiAliasLineRGB, __glNptSmoothRGBZTriangle, __glNptSmoothRGBAZTriangle, __glNptSmoothRGBTriangle, __glNptSmoothRGBATriangle, __glNptSmoothRGBZOptTriangle +7 |
| WRMASK | W sw:3 | 1 | __glNptSetWRMask |
| HOSTRW0 | R lw GO:30, W sw:5, W sw GO:96 | 16 | FastDrawPixels_0, FastDrawPixels_2, FastReadPixels, ReadRGBSpan, ReadRGBPackedSpan, ReadCI +10 |
| HOSTRW0+HOSTRW1 | W sdc1 GO:54 | 27 | __glNptShadeRGBFzSpan_asm, __glNptShadeDepthRGBFzSpan_sLESS_asm, __glNptShadeDepthRGBFzSpan_uLESS_asm, __glNptTexRGBAFzSpan_REPLACE_asm, __glNptTexRGBFzSpan_REPLACE_asm, __glNptTexRGBAFzSpan_MODULATE_asm +21 |
| HOSTRW1 | W sw:2, W sw GO:4 | 4 | __glNptTexDepthRGBAFzSpan_REPLACE, __glNptTexDepthFzSpan_MODULATE, __glNptFillFastTriangle, FastDrawPixels_1 |
| SMASK1X | R lw:2 | 1 | FindWindowSize |
| SMASK1Y | R lw:2 | 1 | FindWindowSize |
| SMASK2X | R lw:2 | 1 | FindWindowSize |
| SMASK2Y | R lw:2 | 1 | FindWindowSize |
| SMASK3X | R lw:2 | 1 | FindWindowSize |
| SMASK3Y | R lw:2 | 1 | FindWindowSize |
| SMASK4X | R lw:2 | 1 | FindWindowSize |
| SMASK4Y | R lw:2 | 1 | FindWindowSize |
| CLIPMODE | R lw:2 | 1 | FindWindowSize |
| CONFIG | R lw:1, W sw:1 | 1 | MakeCurrent |
| USER_STATUS | R lw:33 | 9 | ReadRGBSpan, ReadRGBPackedSpan, ReadCI, FindWindowSize, Finish, FastReadPixels +3 |
### irisgl.so: 977 accesses, 149 functions
| DRAWMODE1 | R lw:1, W sw:48, W sw GO:5 | 30 | _mem8_to_fb, _mem32_to_fb, _mem16_to_fb, __sboxf, __pk_sboxo, gl_czclear +24 |
| DRAWMODE0 | W sw:59, W sw GO:6 | 41 | __pnt_sm, __line_shade, __text_zb, _mem32_to_fb, _mem8_to_fb, _line2d +35 |
| LSMODE | W sw:32 | 31 | drawpatch, _loadattribs, gl_i_lsrepeat, gl_n_lsrepeat, drawcurve, drawcurves +25 |
| LSPATTERN | W sw:33, W sw GO:2 | 29 | _C_line_sm_zb, drawpatch, gl_setlinestyle, drawcurve, drawcurves, gl_i_curveit +23 |
| LSPATSAVE | W sw:1 | 1 | gl_setlinestyle |
| ZPATTERN | W sw:3, W sw GO:59 | 24 | __text, _C_line_sm_zb, _C_line_zb, __subtri_rgb, __subtri_al, __sboxf +18 |
| COLORVRAM | W sw:2 | 1 | __sboxf |
| ALPHAREF | W sw:1 | 1 | gl_afunction |
| SMASK0X | W sw:2 | 2 | gl_do_scrmask, gl_rex_init |
| SMASK0Y | W sw:2 | 2 | gl_do_scrmask, gl_rex_init |
| SETUP | W sw:23 | 15 | _mem32_to_fb, _mem8_to_fb, _C_line_zb, _mem16_to_fb, gl_pixeldma_read, _C_line_sm_zb +9 |
| STEPZ | W sw GO:2 | 1 | _texture_span |
| LSRESTORE | W sw:31 | 28 | drawpatch, __wide, __wide_sh, drawcurve, drawcurves, gl_i_curveit +22 |
| LSSAVE | W sw:4 | 2 | __wide, __wide_sh |
| XYMOVE | W sw:1 | 1 | gl_g_rectcopy |
| BRESOCTINC1 | W sw:11 | 9 | __text, __text_zb, __subtri_al, __subtri_al_zb, __subtri_tex, __subtri +3 |
| BRESE1 | W sw:2 | 2 | _C_line_sm, _C_line_sm_zb |
| AWEIGHT0 | W sw:1 | 1 | gl_setlinestyle |
| AWEIGHT1 | W sw:1 | 1 | gl_setlinestyle |
| XSTARTF | W sw:12, W swc1:16, W swc1 GO:4 | 15 | __sboxf, __sboxo, __pnt_sm, __pnt_sm_alpha, _C_line_zb, __text_zb +9 |
| XSTARTF+YSTARTF | W sdc1:6, W sdc1 GO:6 | 7 | __line_shade, _line2d, __line, _pnt2d, __pnt, __pnt_alpha +1 |
| YSTARTF | W sw:13, W swc1:15, W swc1 GO:2 | 15 | __sboxo, __pnt_sm, __pnt_sm_alpha, _C_line_zb, __sboxf, __wide +9 |
| XENDF | W sw:6, W swc1:19, W swc1 GO:4 | 16 | __text_zb, __sboxo, _C_line_zb, gl_czclear, __subtri_al, __subtri_al_zb +10 |
| XENDF+YENDF | W sdc1:6, W sdc1 GO:2 | 3 | __line_shade, _line2d, __line |
| YENDF | W sw:9, W swc1:7, W swc1 GO:4 | 13 | __sboxo, _C_line_zb, __sboxf, __wide, gl_czclear, __text +7 |
| XSTARTI | W sw:6 | 3 | __subtri_al, __subtri_al_zb, __subtri_tex |
| XSTARTI+XENDF1 | W sdc1:7, W sdc1 GO:4 | 5 | __subtri_rgb, __subtri_zb, __subtri_rgb_zb, __subtri, __subtri_sh |
| XYSTARTI | W sw:55 | 19 | _mem32_to_fb, __subtri_al_zb, __subtri_tex, _fb_to_mem16, _mem8_to_fb, gl_pixeldma_read +13 |
| XYENDI | W sw:28 | 11 | _fb_to_mem16, _mem32_to_fb, _mem8_to_fb, gl_pixeldma_read, _mem16_to_fb, _fb_to_mem8 +5 |
| XSTARTENDI | W sw:20 | 11 | _mem32_to_fb, _mem16_to_fb, _mem8_to_fb, _fb_to_mem16, _fb_rgb_to_mem32, gl_pixeldma_read +5 |
| COLORRED | W swc1:72 | 44 | __line_shade, _C_line_zb, __subtri_rgb, __light_model1, __subtri_rgb_zb, _cc_text_rgb +38 |
| COLORALPHA | W swc1:16 | 12 | _C_line_zb, _pclos_nolink_slowpath, __subtri_al, __light_model1, _color_rgb, _shademodel +6 |
| COLORGREEN | W swc1:34 | 24 | _C_line_zb, __subtri_rgb, __subtri_rgb_zb, _cc_text_rgb, _pclos_nolink_slowpath, __subtri_al +18 |
| COLORGREEN+COLORBLUE | W sdc1:4 | 1 | __line_shade |
| COLORBLUE | W swc1:32, W swc1 GO:1 | 24 | _C_line_zb, __subtri_rgb_zb, _cc_text_rgb, _pclos_nolink_slowpath, __subtri_al, _C_line_sm +18 |
| SLOPERED | W swc1:13 | 9 | __line_shade, _C_line_sm, _C_line_zb, __triang_al, __triang_al_zb, _C_line_sm_zb +3 |
| SLOPEALPHA | W swc1:4 | 4 | _C_line_zb, __triang_al, __triang_al_zb, _C_line_sm_zb |
| SLOPEGREEN | W swc1:8 | 7 | _C_line_sm, _C_line_zb, __triang_al, __triang_al_zb, _C_line_sm_zb, __triang_rgb +1 |
| SLOPEGREEN+SLOPEBLUE | W sdc1:4 | 1 | __line_shade |
| SLOPEBLUE | W swc1:8 | 7 | _C_line_sm, _C_line_zb, __triang_al, __triang_al_zb, _C_line_sm_zb, __triang_rgb +1 |
| WRMASK | W sw:3 | 3 | gl_czclear, gl_set_depthmask, gl_rex_init |
| COLORI | W sw:1, W sw GO:30 | 4 | _mem32_to_fb, _mem16_to_fb, _mem8_to_fb, gl_czclear |
| COLORX | W swc1:1 | 1 | gl_rex_init |
| HOSTRW0 | R lw GO:76, W sw GO:59 | 14 | _fb_rgb_to_mem32, gl_read_span, _fb_to_mem8, _fb_to_mem16, _fb_to_mem32, _mem32_to_fb +8 |
| HOSTRW0+HOSTRW1 | W sdc1 GO:4 | 2 | _mem32_to_fb, _mem8_to_fb |
| HOSTRW1 | W sw:1 | 1 | _mem32_to_fb |
| SMASK1X | R lw:2 | 1 | gl_do_viewport |
| SMASK1Y | R lw:2 | 1 | gl_do_viewport |
| SMASK2X | R lw:2 | 1 | gl_do_viewport |
| SMASK2Y | R lw:2 | 1 | gl_do_viewport |
| SMASK3X | R lw:2 | 1 | gl_do_viewport |
| SMASK3Y | R lw:2 | 1 | gl_do_viewport |
| SMASK4X | R lw:2 | 1 | gl_do_viewport |
| SMASK4Y | R lw:2 | 1 | gl_do_viewport |
| XYWIN | R lw:1 | 1 | gl_getxywin |
| CLIPMODE | R lw:2 | 1 | gl_do_viewport |
| CONFIG | R lw:2, W sw:1 | 1 | gl_set_fifo |
| USER_STATUS | R lw:1 | 1 | gl_finishasm |
### Xsgi: 1188 accesses, 60 functions
| DRAWMODE1 | W sw:82 | 46 | sub_100c0864, rex3ImageGlyphBlt, rex3DrawSolidRects, rex3SolidSpans, rex3SolidFillSpans, rex3SolidPolyFillRect +40 |
| DRAWMODE0 | W sw:92, W sw GO:1 | 46 | rex3LineSS, rex3LineSD, rex3DrawMonoImage, rex3DrawOpaqueMonoImage, rex3ZeroPolyArc, sub_100c0864 +40 |
| LSMODE | W sw:5 | 5 | sub_100c0864, rex3StippledFillRects, rex3StippledFS, rex3LineSD, rex3SegmentSD |
| LSPATTERN | W sw:6, W sw GO:2 | 5 | rex3StippledFillRects, rex3LineSD, rex3SegmentSD, sub_100c0864, rex3StippledFS |
| LSPATSAVE | W sw:1 | 1 | sub_100c0864 |
| ZPATTERN | W sw:1, W sw GO:153 | 14 | rex3ImageGlyphBlt, rex3PolyGlyphBlt, rex3DrawMonoImage, rex3DrawOpaqueMonoImage, rex3ZeroPolyArc, rex3PolyGlyphBltP4C +8 |
| COLORBACK | W sw:6 | 6 | sub_100c0864, rex3StippledFillRects, rex3StippledFS, rex3DrawOpaqueMonoImage, rex3LineSD, rex3SegmentSD |
| COLORVRAM | W sw:11 | 11 | sub_100c0864, rex3ImageGlyphBlt, rex3DrawSolidRects, rex3SolidSpans, rex3SolidFillSpans, rex3ValidateClip +5 |
| SMASK0X | W sw:1 | 1 | sub_100c0864 |
| SMASK0Y | W sw:1 | 1 | sub_100c0864 |
| SETUP | W sw:10 | 4 | rex3ReadImage, rex3ReadImage12, rex3ReadImage24, rex3StippledFillRects |
| XSAVE | W sw:1 | 1 | sub_100c0864 |
| XYMOVE | W sw:1, W sw GO:4 | 4 | rex3TiledFS, sub_100c0864, rex3CopyRect, sub_10102f40 |
| BRESD | W sw:3 | 3 | sub_100c0864, rex3LineSS, rex3SegmentSS |
| BRESS1 | W sw:1 | 1 | sub_100c0864 |
| BRESOCTINC1 | W sw:31 | 28 | rex3DrawImage, rex3DrawImage24, rex3DrawImage12, sub_100c0864, rex3ImageGlyphBlt, rex3PolyGlyphBlt +22 |
| BRESRNDINC2 | W sw:1 | 1 | sub_100c0864 |
| BRESE1 | W sw:1 | 1 | sub_100c0864 |
| BRESS2 | W sw:1 | 1 | sub_100c0864 |
| AWEIGHT0 | W sw:1 | 1 | sub_100c0864 |
| AWEIGHT1 | W sw:1 | 1 | sub_100c0864 |
| XYSTARTI | W sw:101, W sw GO:102 | 48 | rex3PolyPoint, sub_1010c468, sub_1010c748, rex3SolidZeroSeg, rex3SolidFillSpans, rex3LineSS +42 |
| XYENDI | W sw:90, W sw GO:64 | 44 | rex3LineSD, rex3SolidZeroSeg, rex3LineSS, rex3SolidFillSpans, rex3DrawMonoImage, rex3DrawOpaqueMonoImage +38 |
| COLORRED | W sw:1 | 1 | sub_100c0864 |
| COLORALPHA | W sw:1 | 1 | sub_100c0864 |
| COLORGREEN | W sw:1 | 1 | sub_100c0864 |
| COLORBLUE | W sw:1 | 1 | sub_100c0864 |
| WRMASK | W sw:51 | 42 | sub_100c0864, rex3StippledFillRects, rex3DrawImage, rex3DrawImage24, rex3DrawImage12, rex3ImageGlyphBlt +36 |
| COLORI | W sw:42 | 33 | sub_100c0864, rex3ImageGlyphBlt, rex3StippledFillRects, rex3ImageGlyphBltP2C, rex3ImageGlyphBltP3C, rex3ImageGlyphBltP4C +27 |
| HOSTRW0 | R lw GO:24, W sw GO:104 | 11 | sub_101096a0, rex3TiledFS, rex3ReadImage, rex3ReadImage12, rex3ReadImage24, rex3RDReadPixels +5 |
| HOSTRW1 | W sw:2 | 2 | sub_100ffd24, rex3TiledFS8_W4 |
| DCBMODE | R lw:3, W sw:43 | 10 | sub_100c29d8, sub_100f7430, sub_100c1758, sub_100c0864, rex3InstallCursor, rex3BlankScreen +4 |
| DCBDATA0 | R lbu +3:12, R lhu +2:1, W sb +3:9, W sh +2:10, W sw:18 | 10 | sub_100c29d8, sub_100c0864, sub_100c1758, sub_100f7430, rex3InstallCursor, rex3BlankScreen +4 |
| SMASK1X | W sw:1 | 1 | sub_100fe764 |
| SMASK1Y | W sw:1 | 1 | sub_100fe764 |
| SMASK2X | W sw:1 | 1 | sub_100fe764 |
| SMASK2Y | W sw:1 | 1 | sub_100fe764 |
| SMASK3X | W sw:1 | 1 | sub_100fe764 |
| SMASK3Y | W sw:1 | 1 | sub_100fe764 |
| SMASK4X | W sw:1 | 1 | sub_100fe764 |
| SMASK4Y | W sw:1 | 1 | sub_100fe764 |
| XYWIN | W sw:14 | 8 | rex3LineSS, rex3PolyPoint, rex3SegmentSS, rex3DrawPoints, rex3LineSD, rex3SegmentSD +2 |
| CLIPMODE | W sw:21 | 20 | rex3ZeroPolyArc, sub_100c0864, rex3ImageGlyphBlt, rex3PolyGlyphBlt, rex3PolyGlyphBltP4C, rex3ImageGlyphBltP2C +14 |
| CONFIG | R lw:1, W sw:1 | 1 | sub_100c0864 |
| USER_STATUS | R lw:45 | 7 | sub_100c0864, sub_100c29d8, sub_100f7430, rex3ReadImage, rex3ReadImage12, rex3ReadImage24 +1 |
### unix: 984 accesses, 36 functions
| DRAWMODE1 | R lw:1, W sw:15 | 4 | rex3Clear, fbdepth, newportPcxSwap, initRex3 |
| DRAWMODE0 | R lw:1, W sw:7, W sw GO:3 | 6 | fbdepth, newportPcxSwap, rex3Clear, newport_sboxfi, newport_pnt2i, newport_drawbitmap |
| LSMODE | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| LSPATTERN | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| LSPATSAVE | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| ZPATTERN | R lw:1, W sw:2, W sw GO:42 | 3 | newport_drawbitmap, newportPcxSwap, initRex3 |
| COLORBACK | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| COLORVRAM | R lw:1, W sw:3 | 3 | newportPcxSwap, initRex3, fbdepth |
| ALPHAREF | R lw:1, W sw:1 | 1 | newportPcxSwap |
| SMASK0X | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| SMASK0Y | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| XSTART | R lw:2, W sw:1 | 2 | newportPcxSwap, newportProbe |
| YSTART | R lw:1, W sw:1 | 1 | newportPcxSwap |
| XEND | R lw:1, W sw:1 | 1 | newportPcxSwap |
| YEND | R lw:1, W sw:1 | 1 | newportPcxSwap |
| XSAVE | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| XYMOVE | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| BRESD | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| BRESS1 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| BRESOCTINC1 | R lw:1, W sw:7 | 4 | fbdepth, newportPcxSwap, initRex3, newport_drawbitmap |
| BRESRNDINC2 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| BRESE1 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| BRESS2 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| AWEIGHT0 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| AWEIGHT1 | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| XSTARTI | W sw:1 | 1 | newportProbe |
| XYSTARTI | W sw:13, W sw GO:1 | 5 | fbdepth, rex3Clear, newport_drawbitmap, newport_sboxfi, newport_pnt2i |
| XYENDI | W sw:8, W sw GO:5 | 4 | fbdepth, rex3Clear, newport_drawbitmap, newport_sboxfi |
| COLORRED | R lw:1, W sw:3 | 2 | newportPcxSwap, initRex3 |
| COLORALPHA | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| COLORGREEN | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| COLORBLUE | R lw:1, W sw:2 | 2 | newportPcxSwap, initRex3 |
| SLOPERED | R lw:1, W sw:2 | 1 | newportPcxSwap |
| SLOPEALPHA | R lw:1, W sw:2 | 1 | newportPcxSwap |
| SLOPEGREEN | R lw:1, W sw:2 | 1 | newportPcxSwap |
| SLOPEBLUE | R lw:1, W sw:2 | 1 | newportPcxSwap |
| WRMASK | R lw:1, W sw:10 | 4 | rex3Clear, newportPcxSwap, fbdepth, initRex3 |
| COLORI | W sw:6 | 3 | rex3Clear, fbdepth, newport_color |
| HOSTRW0 | R lw:1, R lw GO:4, W sw:1, W sw GO:2 | 2 | fbdepth, newportPcxSwap |
| HOSTRW1 | R lw:1, W sw:1 | 1 | newportPcxSwap |
| DCBMODE | R lw:14, W sw:219 | 21 | initClock, initCMAP, ng1_setvideotiming, newportSetGammaRamp, initVC2, newportRetraceHandler +15 |
| DCBDATA0 | R lbu +3:39, R lhu +2:4, W sb +3:104, W sh +2:14, W sw:37 | 19 | initClock, initCMAP, ng1_setvideotiming, newportSetGammaRamp, initVC2, initXMAP9 +13 |
| SMASK1X | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK1Y | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK2X | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK2Y | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK3X | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK3Y | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK4X | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| SMASK4Y | R lw:1, W sw:2 | 2 | newportPcxSwap, newportValidateClip |
| TOPSCAN | R lw:4, W sw:2 | 4 | ng1_error, newportInitialize, ng1_setvideotiming, newportInit |
| XYWIN | R lw:1, W sw:4 | 4 | newportPcxSwap, newportValidateClip, initRex3, newportInit |
| CLIPMODE | R lw:1, W sw:3 | 3 | newportPcxSwap, newportValidateClip, initRex3 |
| CONFIG | R lw:2, W sw:7 | 6 | ng1_error, newportPcxSwap, fbdepth, newportFIFO, newportProbe, initRex3 |
| STATUS | R lw:6 | 5 | newportProbe, ip22_newportInterrupt, ip24_newportInterrupt, newportInitInfo, ng1_i2cProbe |
| USER_STATUS | R lw:277 | 28 | initClock, fbdepth, newport_drawbitmap, initCMAP, newportPcxSwap, newportSetGammaRamp +22 |
| DCBRESET | W sw:2 | 2 | initRex3, ng1_i2cProbe |
### boot.rom: 592 accesses, 26 functions
| DRAWMODE1 | W sw:7 | 2 | sub_bfc1918c, sub_bfc18ddc |
| DRAWMODE0 | W sw:6, W sw GO:3 | 8 | sub_bfc18ddc, sub_bfc089f8, sub_bfc08a54, sub_bfc1918c, sub_bfc368b0, sub_bfc36960 +2 |
| LSMODE | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| LSPATTERN | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| LSPATSAVE | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| ZPATTERN | W sw:2, W sw GO:36 | 3 | sub_bfc36a04, sub_bfc08710, sub_bfc18f10 |
| COLORBACK | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| COLORVRAM | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| SMASK0X | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| SMASK0Y | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| XSTART | R lw:1 | 1 | sub_bfc1756c |
| XSAVE | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| XYMOVE | W sw:2, W sw GO:1 | 3 | sub_bfc08710, sub_bfc18f10, sub_bfc36fcc |
| BRESD | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| BRESS1 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| BRESOCTINC1 | W sw:3 | 3 | sub_bfc08710, sub_bfc18f10, sub_bfc36a04 |
| BRESRNDINC2 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| BRESE1 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| BRESS2 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| AWEIGHT0 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| AWEIGHT1 | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| XSTARTI | W sw:1 | 1 | sub_bfc1756c |
| XYSTARTI | W sw:11, W sw GO:1 | 6 | sub_bfc1918c, sub_bfc36a04, sub_bfc18ddc, sub_bfc368b0, sub_bfc36960, sub_bfc36fcc |
| XYENDI | W sw:5, W sw GO:5 | 5 | sub_bfc1918c, sub_bfc36a04, sub_bfc18ddc, sub_bfc368b0, sub_bfc36fcc |
| COLORRED | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| COLORALPHA | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| COLORGREEN | W sw:1 | 1 | sub_bfc18f10 |
| COLORBLUE | W sw:1 | 1 | sub_bfc18f10 |
| WRMASK | W sw:8 | 4 | sub_bfc1918c, sub_bfc08710, sub_bfc18ddc, sub_bfc18f10 |
| COLORI | W sw:5 | 2 | sub_bfc1918c, sub_bfc36780 |
| HOSTRW0 | R lw GO:1, W sw GO:1 | 1 | sub_bfc18ddc |
| DCBMODE | R lw:1, W sw:153 | 16 | sub_bfc17ba4, sub_bfc18850, sub_bfc18590, sub_bfc17820, sub_bfc18b48, sub_bfc195f4 +10 |
| DCBDATA0 | R lbu +3:12, R lhu +2:5, W sb +3:97, W sh +2:9, W sw:30 | 16 | sub_bfc17ba4, sub_bfc18850, sub_bfc18590, sub_bfc17820, sub_bfc18b48, sub_bfc195f4 +10 |
| SMASK1X | W sw:1 | 1 | sub_bfc08710 |
| SMASK1Y | W sw:1 | 1 | sub_bfc08710 |
| SMASK2X | W sw:1 | 1 | sub_bfc08710 |
| SMASK2Y | W sw:1 | 1 | sub_bfc08710 |
| SMASK3X | W sw:1 | 1 | sub_bfc08710 |
| SMASK3Y | W sw:1 | 1 | sub_bfc08710 |
| SMASK4X | W sw:1 | 1 | sub_bfc08710 |
| SMASK4Y | W sw:1 | 1 | sub_bfc08710 |
| TOPSCAN | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| XYWIN | R lw:1, W sw:4 | 3 | sub_bfc1918c, sub_bfc08710, sub_bfc18f10 |
| CLIPMODE | W sw:2 | 2 | sub_bfc08710, sub_bfc18f10 |
| CONFIG | W sw:3 | 3 | sub_bfc08710, sub_bfc1756c, sub_bfc18ddc |
| STATUS | R lw:3 | 3 | sub_bfc1756c, sub_bfc17820, sub_bfc34fc0 |
| USER_STATUS | R lw:126 | 20 | sub_bfc17ba4, sub_bfc36a04, sub_bfc1918c, sub_bfc18850, sub_bfc18b48, sub_bfc18ddc +14 |
| DCBRESET | W sw:1 | 1 | sub_bfc34fc0 |
