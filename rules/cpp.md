---
paths:
  - "**/*.{c,cc,cpp,cxx,h,hpp,hxx}"
  - "**/CMakeLists.txt"
  - "**/CMakePresets.json"
  - "**/vcpkg.json"
---

# C / C++ 規則

## 新專案預設
- 語言標準：C++20、C17
- CMake ≥ 3.20 + `CMakePresets.json`
- vcpkg manifest mode（Conan 2 替代）
- GoogleTest（Catch2 替代）
- Compiler matrix：Win → MSVC v143 + MinGW-w64 GCC（CI 兩者都跑）；macOS → Apple Clang；Linux → GCC 11+ / Clang 14+
- Dev + CI 啟 ASan + UBSan，多執行緒加 TSan
- Committed `.clang-format` + `.clang-tidy`

## 維運既有 C / C++98
- 沿用既有風格不主動現代化
