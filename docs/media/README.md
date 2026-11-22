# 宣传片（抖音竖屏）

`ios-on-windows-promo-1080x1920.mp4` — 92.0 s，1080×1920，H.264 / AAC，3.3 MB。

| 项 | 值 |
|---|---|
| 发布 | 抖音，2026-11-22 22:47，标题「没有 Mac，也能编出一个 iOS App」 |
| 分镜 | 9 个镜头：没有 Mac → 换编译器 + 手写符号表 → 自写 codesign + ipa → 9 项检查 → 模拟器跑通 → 证据 → 诚实的两个未知数 |
| 片内数字 | `verify-ipa` 9/0/0、`audit --target trollstore` FATAL=0、`pytest` 14 passed、`sim-ios` PASS |
| 口播 | edge-tts `zh-CN-YunjianNeural`，-10%，90.6 s |
| 画面 | 与 X-Rec 同一套视觉基线；深色镜头留给「真的跑起来」的调用链 |

重渲方式（工具链在 `F:\shit\toolchain\video`）：

```powershell
$P = "F:\shit\toolchain\video\projects\ios-promo"
python F:\shit\toolchain\video\tts_edge.py --project $P --rate=-10%
python $P\build_scenes.py --render
python F:\shit\toolchain\video\make_srt.py --sent $P\_work\voice\sentences.json --out $P\_work\sub.srt
python F:\shit\toolchain\video\make_bgm.py --dur 101 --out $P\_work\bgm.wav
python F:\shit\toolchain\video\assemble.py --project $P --name ios-成片 --size 1080x1920
```
