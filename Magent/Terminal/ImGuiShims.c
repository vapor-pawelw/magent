// Shims for missing ImGui C-wrapper constructor symbols.
// The Zig build of libghostty references these C-style constructor wrappers,
// but the cimgui/dcimgui build doesn't always emit them. We forward to the
// C++ constructors.

#ifdef __cplusplus
extern "C" {
#endif

// C++ constructor declarations (mangled names resolved by linker)
void _ZN12ImFontConfigC1Ev(void* self);
void _ZN10ImGuiStyleC1Ev(void* self);

void ImFontConfig_ImFontConfig(void* self) {
    _ZN12ImFontConfigC1Ev(self);
}

void ImGuiStyle_ImGuiStyle(void* self) {
    _ZN10ImGuiStyleC1Ev(self);
}

#ifdef __cplusplus
}
#endif
