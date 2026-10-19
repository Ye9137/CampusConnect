using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using Microsoft.ML.OnnxRuntime;
using System.Text.Json;

namespace CampusConnect;

internal sealed record CaptchaRecognition(string Digits, string Placeholder, string Hint, string Engine = "");

internal static class CaptchaOcr
{
    private static readonly SemaphoreSlim RecognitionGate = new(1, 1);
    internal static async Task<CaptchaRecognition> RecognizeAsync(byte[] bytes, int expectedLength = 0, CancellationToken cancellationToken = default)
    {
        await RecognitionGate.WaitAsync(cancellationToken);
        try {
            CaptchaRecognition model;
            using (var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)) {
                budget.CancelAfter(TimeSpan.FromSeconds(6));
                try {
                    model = CaptchaModel.Recognize(bytes, expectedLength, budget.Token);
                    if (model.Digits.Length > 0 || model.Placeholder == "识别结果不一致") return model;
                } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) {
                    model = new("", "模型识别超时", "本地模型识别用时较长，请根据原图输入。");
                } catch (Exception ex) when (ex is OnnxRuntimeException or TypeInitializationException or DllNotFoundException
                    or BadImageFormatException or EntryPointNotFoundException or IOException or JsonException or ArgumentException) {
                    model = new("", "本地模型不可用", "本地模型或运行库未能加载，可重新运行安装程序补全组件并重启；当前可根据原图输入。");
                }
            }
            cancellationToken.ThrowIfCancellationRequested();
            var system = await RecognizeWindowsAsync(bytes, expectedLength, cancellationToken);
            return system.Digits.Length > 0 ? system with { Engine = "系统识别参考" } : model;
        } finally { RecognitionGate.Release(); }
    }

    private static async Task<CaptchaRecognition> RecognizeWindowsAsync(byte[] bytes, int expectedLength, CancellationToken cancellationToken)
    {
        try {
            var languages = OcrEngine.AvailableRecognizerLanguages;
            if (languages.Count == 0) return new("", "缺少识别语言包", "Windows 未安装可用的 OCR 语言包，请先根据原图输入数字。");
            var engines = new List<OcrEngine>();
            void Add(OcrEngine? engine) {
                if (engine is not null && !engines.Any(e => e.RecognizerLanguage.LanguageTag == engine.RecognizerLanguage.LanguageTag)) engines.Add(engine);
            }
            var english = languages.FirstOrDefault(l => l.LanguageTag.StartsWith("en", StringComparison.OrdinalIgnoreCase));
            if (english is not null) Add(OcrEngine.TryCreateFromLanguage(english));
            Add(OcrEngine.TryCreateFromUserProfileLanguages());
            if (engines.Count == 0) Add(OcrEngine.TryCreateFromLanguage(languages[0]));
            if (engines.Count == 0) return new("", "识别组件不可用", "Windows 文字识别组件暂不可用，请直接根据原图输入数字。");

            // Count agreement between image variants, not between languages reading the same variant.
            var candidates = new Dictionary<string, HashSet<int>>(StringComparer.Ordinal);
            var variantIndex = 0;
            foreach (var variant in Variants(bytes, (int)Math.Min(OcrEngine.MaxImageDimension, 2048u))) {
                cancellationToken.ThrowIfCancellationRequested();
                using var bitmap = await DecodeAsync(variant, cancellationToken);
                foreach (var engine in engines.Take(2)) {
                    cancellationToken.ThrowIfCancellationRequested();
                    var result = await engine.RecognizeAsync(bitmap).AsTask(cancellationToken);
                    var digits = DigitsFromText(result.Text, expectedLength);
                    if (digits.Length == 0) continue;
                    if (!candidates.TryGetValue(digits, out var votes)) candidates[digits] = votes = [];
                    votes.Add(variantIndex);
                    if (votes.Count >= 2) return new(digits, "", "请核对原图，再复制或输入识别数字。");
                }
                variantIndex++;
            }
            if (candidates.Count == 1) return new(candidates.Keys.Single(), "", "识别结果仅供参考，请核对原图后再复制或输入。");
            return candidates.Count > 1
                ? new("", "识别结果不一致", "不同处理方式的识别结果不一致，请根据原图手动输入。")
                : new("", "未识别出数字", "放大及去干扰后仍未识别出数字，请直接根据原图输入。");
        } catch (OperationCanceledException) { throw; }
        catch (Exception ex) when (ex is COMException or TypeLoadException or DllNotFoundException or PlatformNotSupportedException) {
            return new("", "识别组件不可用", "系统文字识别组件无法使用，请直接根据原图输入数字。");
        }
    }

    internal static string DigitsFromText(string text, int expectedLength)
    {
        var digits = new StringBuilder();
        foreach (var character in text.Normalize(NormalizationForm.FormKC)) {
            if (character is >= '0' and <= '9') digits.Append(character);
            else if (!char.IsWhiteSpace(character) && !"-—_.,:;~·、'`".Contains(character)) return "";
        }
        var value = digits.ToString();
        // Without a declared length, do not offer a lone fragment as a complete code.
        return value.Length is > 0 and <= 12 && (expectedLength > 0 ? value.Length == expectedLength : value.Length >= 3) ? value : "";
    }

    private static async Task<SoftwareBitmap> DecodeAsync(byte[] bytes, CancellationToken cancellationToken)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) {
            writer.WriteBytes(bytes);
            await writer.StoreAsync().AsTask(cancellationToken);
            await writer.FlushAsync().AsTask(cancellationToken);
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellationToken);
        return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied).AsTask(cancellationToken);
    }

    private static IEnumerable<byte[]> Variants(byte[] bytes, int maximumDimension)
    {
        using var input = new MemoryStream(bytes);
        using var source = System.Drawing.Image.FromStream(input);
        if (source.Width > 1024 || source.Height > 512 || maximumDimension < Math.Max(source.Width, source.Height) + 32)
            throw new InvalidDataException("验证码图片尺寸不可用。");
        using var flat = new Bitmap(source.Width, source.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(flat)) { graphics.Clear(Color.White); graphics.DrawImageUnscaled(source, 0, 0); }
        var scale = Math.Clamp((maximumDimension - 32) / Math.Max(flat.Width, flat.Height), 1, 4);
        // Color mask removes gray/black interference without discarding bright yellow/cyan digits.
        foreach (var mode in new[] { "color", "original", "minimum", "gray", "threshold" }) {
            using var normalized = new Bitmap(flat);
            if (mode != "original") {
                var rectangle = new Rectangle(0, 0, normalized.Width, normalized.Height);
                var data = normalized.LockBits(rectangle, ImageLockMode.ReadWrite, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                try {
                    var pixels = new byte[Math.Abs(data.Stride) * normalized.Height];
                    if (data.Stride < 0) throw new InvalidDataException("验证码图片方向不可用。");
                    Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                    for (var y = 0; y < normalized.Height; y++) for (var x = 0; x < normalized.Width; x++) {
                        var p = y * data.Stride + x * 4;
                        var blue = pixels[p]; var green = pixels[p + 1]; var red = pixels[p + 2];
                        var minimum = Math.Min(red, Math.Min(green, blue));
                        var maximum = Math.Max(red, Math.Max(green, blue));
                        var luminance = (red * 299 + green * 587 + blue * 114) / 1000;
                        var value = mode switch {
                            "color" => maximum - minimum >= 32 && minimum < 235 ? 0 : 255,
                            "minimum" => minimum < 175 ? 0 : 255,
                            "gray" => luminance,
                            _ => luminance < 180 ? 0 : 255
                        };
                        pixels[p] = pixels[p + 1] = pixels[p + 2] = (byte)value; pixels[p + 3] = 255;
                    }
                    Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
                } finally { normalized.UnlockBits(data); }
            }
            using var enlarged = new Bitmap(flat.Width * scale + 32, flat.Height * scale + 32);
            using (var graphics = Graphics.FromImage(enlarged)) {
                graphics.Clear(Color.White); graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(normalized, new Rectangle(16, 16, flat.Width * scale, flat.Height * scale));
            }
            using var png = new MemoryStream(); enlarged.Save(png, ImageFormat.Png);
            yield return png.ToArray();
        }
    }
}
