using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace CampusConnect;

// Pinned ddddocr 1.5.6 non-beta model. No Python, network calls or image files.
internal static class CaptchaModel
{
    private const int Classes = 8210;
    private const string ModelHash = "b8f2ad9cbc1f2e3922a6cb9459e30824e7e2467f3fb4fd61420640e34ea0bf68";
    private const string DictionaryHash = "38d6dea58f55839412536c4cccfc939ec3bd4905af13bdc61e853ae4aa17b756";
    private static readonly Lazy<ModelResources> Resources = new(() => new ModelResources());

    internal static CaptchaRecognition Recognize(byte[] bytes, int expectedLength, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var model = Resources.Value;
        cancellationToken.ThrowIfCancellationRequested();
        using var stream = new MemoryStream(bytes);
        using var source = System.Drawing.Image.FromStream(stream);
        if (source.Width > 1024 || source.Height > 512 || source.Height <= 0)
            throw new InvalidDataException("验证码图片尺寸不可用。");
        var width = (int)(source.Width * (64.0 / source.Height));
        if (width is < 8 or > 1024) return new("", "图片比例不适用", "本地模型不适用此图片比例，请根据原图输入。");
        using var image = new Bitmap(width, 64, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(image)) {
            graphics.Clear(Color.White);
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            using var attributes = new ImageAttributes();
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            graphics.DrawImage(source, new Rectangle(0, 0, width, 64), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
        }
        var (gray, colorMask) = Inputs(image);
        var candidates = new Dictionary<string, List<double>>(StringComparer.Ordinal);
        foreach (var pixels in colorMask is null ? new[] { gray } : new[] { gray, colorMask }) {
            cancellationToken.ThrowIfCancellationRequested();
            var tensor = new DenseTensor<float>(pixels, new[] { 1, 1, 64, width });
            using var options = new RunOptions();
            using var registration = cancellationToken.Register(() => options.Terminate = true);
            try {
                using var output = model.Session.Run(new[] { NamedOnnxValue.CreateFromTensor("input1", tensor) }, model.Session.OutputNames, options);
                cancellationToken.ThrowIfCancellationRequested();
                var candidate = Decode(output.First().AsTensor<float>(), model.Digits, expectedLength, cancellationToken);
                if (candidate.Digits.Length == 0) continue;
                if (!candidates.TryGetValue(candidate.Digits, out var scores)) candidates[candidate.Digits] = scores = [];
                scores.Add(candidate.Score);
            } catch (OnnxRuntimeException) when (cancellationToken.IsCancellationRequested) {
                throw new OperationCanceledException(cancellationToken);
            }
        }
        if (candidates.Count == 1) {
            var pair = candidates.Single();
            // Softmax scores only reject weak results; they are not measured accuracy.
            if (pair.Value.Count >= 2 || pair.Value.Max() >= 0.90)
                return new(pair.Key, "", "请核对原图，再复制或输入识别数字。", "本地模型识别参考");
        }
        return candidates.Count > 1
            ? new("", "识别结果不一致", "本地模型的不同处理结果不一致，请根据原图手动输入。")
            : new("", "模型未获得可靠数字", "本地模型未获得可靠数字，请根据原图手动输入。");
    }

    private static (float[] Gray, float[]? ColorMask) Inputs(Bitmap image)
    {
        var data = image.LockBits(new Rectangle(0, 0, image.Width, image.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            if (data.Stride <= 0) throw new InvalidDataException("验证码图片方向不可用。");
            var bgra = new byte[data.Stride * image.Height];
            Marshal.Copy(data.Scan0, bgra, 0, bgra.Length);
            var gray = new float[image.Width * image.Height];
            var mask = new float[gray.Length];
            var colored = 0;
            for (var y = 0; y < image.Height; y++) for (var x = 0; x < image.Width; x++) {
                var i = y * image.Width + x; var p = y * data.Stride + x * 4;
                var b = bgra[p]; var g = bgra[p + 1]; var r = bgra[p + 2];
                var minimum = Math.Min(r, Math.Min(g, b));
                var maximum = Math.Max(r, Math.Max(g, b));
                // Match upstream grayscale normalization; alpha was flattened onto white.
                var luminance = (r * 299 + g * 587 + b * 114 + 500) / 1000;
                gray[i] = luminance / 127.5f - 1;
                var digitColor = maximum - minimum >= 32 && minimum < 235;
                mask[i] = digitColor ? -1 : 1;
                if (digitColor) colored++;
            }
            return (gray, colored >= gray.Length / 200 ? mask : null);
        } finally { image.UnlockBits(data); }
    }

    private static (string Digits, double Score) Decode(Tensor<float> tensor, IReadOnlyDictionary<int, string> digits,
        int expectedLength, CancellationToken cancellationToken)
    {
        // Upstream's declared output metadata is incomplete. Its final reshape
        // yields time x batch(1) x 8210; require that layout at execution time.
        var shape = tensor.Dimensions;
        if (shape.Length != 3 || shape[1] != 1 || shape[2] != Classes || shape[0] is < 1 or > 512)
            throw new InvalidDataException("模型输出结构不匹配。");
        var values = tensor.ToArray();
        var text = new StringBuilder();
        var previous = 0;
        var logScore = 0.0;
        var count = 0;
        var peak = 0.0;
        bool FinishRun() {
            if (previous == 0) return true;
            if (!digits.TryGetValue(previous, out var digit) || digit.Length != 1 || peak < 0.50) return false;
            text.Append(digit); logScore += Math.Log(peak); count++;
            return count <= 12;
        }
        for (var row = 0; row < shape[0]; row++) {
            cancellationToken.ThrowIfCancellationRequested();
            var offset = row * Classes;
            var best = 0;
            var maximum = values[offset];
            if (!float.IsFinite(maximum)) return ("", 0);
            for (var c = 1; c < Classes; c++) {
                var value = values[offset + c];
                if (!float.IsFinite(value)) return ("", 0);
                if (value > maximum) { maximum = value; best = c; }
            }
            if (best != previous) {
                if (!FinishRun()) return ("", 0);
                previous = best; peak = 0;
            }
            if (best != 0) {
                // Decode over ALL classes, then reject non-digits. Never turn
                // a letter into a plausible digit by masking the other classes.
                if (!digits.ContainsKey(best)) return ("", 0);
                var denominator = 0.0;
                for (var c = 0; c < Classes; c++) denominator += Math.Exp(values[offset + c] - maximum);
                peak = Math.Max(peak, 1.0 / denominator);
            }
        }
        if (!FinishRun() || count == 0) return ("", 0);
        var score = Math.Exp(logScore / count);
        var valueText = CaptchaOcr.DigitsFromText(text.ToString(), expectedLength);
        return score >= 0.75 ? (valueText, score) : ("", 0);
    }

    private sealed class ModelResources
    {
        internal readonly InferenceSession Session;
        internal readonly Dictionary<int, string> Digits;
        internal ModelResources()
        {
            var directory = Path.Combine(AppContext.BaseDirectory, "models");
            var model = ReadVerified(Path.Combine(directory, "captcha-common.onnx"), ModelHash);
            var dictionary = ReadVerified(Path.Combine(directory, "captcha-digits.json"), DictionaryHash);
            using (var json = JsonDocument.Parse(dictionary)) {
                var root = json.RootElement;
                if (root.GetProperty("classes").GetInt32() != Classes || root.GetProperty("blank").GetInt32() != 0)
                    throw new InvalidDataException("模型字典结构不匹配。");
                Digits = root.GetProperty("digits").EnumerateObject().ToDictionary(p => int.Parse(p.Name, System.Globalization.CultureInfo.InvariantCulture), p => p.Value.GetString()!);
                if (Digits.Count != 11 || Digits[0] != "" ||
                    !Digits.Values.Where(v => v.Length == 1).Order().SequenceEqual("0123456789".Select(c => c.ToString())))
                    throw new InvalidDataException("模型数字字典不完整。");
            }
            using var options = new SessionOptions {
                InterOpNumThreads = 1, IntraOpNumThreads = 2,
                ExecutionMode = ExecutionMode.ORT_SEQUENTIAL,
                LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR
            };
            Session = new InferenceSession(model, options);
            if (Session.InputNames.Count != 1 || Session.InputNames[0] != "input1" || Session.OutputNames.Count != 1) {
                Session.Dispose();
                throw new InvalidDataException("模型输入输出不匹配。");
            }
            // Reuse one session; release it after all application windows close.
            AppDomain.CurrentDomain.ProcessExit += (_, _) => Session.Dispose();
        }
        private static byte[] ReadVerified(string path, string expected)
        {
            var bytes = File.ReadAllBytes(path);
            if (!Convert.ToHexStringLower(SHA256.HashData(bytes)).Equals(expected, StringComparison.Ordinal))
                throw new InvalidDataException("模型文件校验失败。");
            return bytes;
        }
    }
}
