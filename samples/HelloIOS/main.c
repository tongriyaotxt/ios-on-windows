/* 零 macOS 路线里唯一“需要真编译器”的那部分。
 *
 * 装上 LLVM（clang + ld64.lld）后，Build-IosApp.ps1 会编译本文件：
 *   clang -target arm64-apple-ios17.0 -c main.c -o main.o
 *   ld64.lld -arch arm64 -platform_version ios 17.0 17.0 -e _main -o HelloIOS main.o
 *
 * 注意这里刻意不 import 任何头文件：iOS SDK 的头文件只有 Xcode 里有。
 * 想写带界面的 App，需要 UIKit 头文件 + .tbd 存根 + Swift 的 .swiftmodule，
 * 那三样只有 macOS 侧的 Xcode 能提供 —— 见 docs/07-NO-MACOS-AT-ALL.md 的边界表。
 */
int main(void) {
    return 0;
}
