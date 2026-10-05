# Génère les images du logo KALETA à partir du logo officiel du restaurant
# (mobile/assets/images/logo_source.png : masque africain vert, couverts dorés, texte « KALETA — Terrasse - Lounge »,
# sur fond blanc ; tiré de la galerie du site menukaleta.netlify.app).
#   mobile/assets/images/logo_full.png        logo complet, fond blanc rendu transparent
#   mobile/assets/images/logo_mask.png        le masque seul (transparent), affiché dans l'app par AppLogo
#   mobile/assets/images/logo.png             icône carrée (iOS, Android classique) : masque sur vert nuit
#   mobile/assets/images/logo_foreground.png  avant-plan de l'icône adaptative Android (fond #03150F fourni par Android)
#   backend/public/logo.png                   logo des pages web du serveur (pastille ronde vert nuit)
# Windows : powershell -ExecutionPolicy Bypass -File mobile/tool/make_logo.ps1
# puis, dans mobile/ : dart run flutter_launcher_icons
param([string]$Root = (Resolve-Path "$PSScriptRoot\..\..").Path)
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class KaletaLogo {
  static bool IsBackground(byte r, byte g, byte b) {
    int min = Math.Min(r, Math.Min(g, b)), max = Math.Max(r, Math.Max(g, b));
    return min >= 215 && (max - min) <= 40;
  }

  /// Fond blanc relié aux bords → transparent (remplissage), puis adoucissement du liseré clair.
  public static Bitmap RemoveWhite(Bitmap src) {
    int w = src.Width, h = src.Height;
    var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) g.DrawImage(src, 0, 0, w, h);
    var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    var px = new byte[w * h * 4];
    Marshal.Copy(data.Scan0, px, 0, px.Length);
    var bg = new bool[w * h];
    var q = new Queue<int>();
    Action<int, int> push = (x, y) => {
      int i = y * w + x;
      if (bg[i]) return;
      int o = i * 4;
      if (!IsBackground(px[o + 2], px[o + 1], px[o])) return;
      bg[i] = true; q.Enqueue(i);
    };
    for (int x = 0; x < w; x++) { push(x, 0); push(x, h - 1); }
    for (int y = 0; y < h; y++) { push(0, y); push(w - 1, y); }
    while (q.Count > 0) {
      int i = q.Dequeue(), x = i % w, y = i / w;
      if (x > 0) push(x - 1, y);
      if (x < w - 1) push(x + 1, y);
      if (y > 0) push(x, y - 1);
      if (y < h - 1) push(x, y + 1);
    }
    for (int i = 0; i < w * h; i++) {
      int o = i * 4;
      if (bg[i]) { px[o + 3] = 0; continue; }
      // Liseré : pixel clair voisin du fond → alpha selon sa clarté (pas de halo blanc sur fond sombre).
      int x = i % w, y = i / w;
      bool edge = (x > 0 && bg[i - 1]) || (x < w - 1 && bg[i + 1]) || (y > 0 && bg[i - w]) || (y < h - 1 && bg[i + w]);
      if (!edge) continue;
      int min = Math.Min(px[o], Math.Min(px[o + 1], px[o + 2]));
      if (min > 150) px[o + 3] = (byte)Math.Max(0, Math.Min(255, (255 - min) * 255 / 105));
    }
    Marshal.Copy(px, 0, data.Scan0, px.Length);
    bmp.UnlockBits(data);
    return bmp;
  }

  /// Lignes contenant au moins un pixel opaque.
  public static bool[] OpaqueRows(Bitmap bmp, out int left, out int right) {
    int w = bmp.Width, h = bmp.Height;
    var rows = new bool[h];
    left = w; right = 0;
    var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var px = new byte[w * h * 4];
    Marshal.Copy(data.Scan0, px, 0, px.Length);
    bmp.UnlockBits(data);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++)
        if (px[(y * w + x) * 4 + 3] > 40) { rows[y] = true; if (x < left) left = x; if (x > right) right = x; }
    return rows;
  }

  /// Colonnes opaques entre deux lignes (pour recadrer le masque seul).
  public static int[] ColumnSpan(Bitmap bmp, int top, int bottom) {
    int w = bmp.Width, l = w, r = 0;
    for (int y = top; y <= bottom; y++)
      for (int x = 0; x < w; x++)
        if (bmp.GetPixel(x, y).A > 40) { if (x < l) l = x; if (x > r) r = x; }
    return new[] { l, r };
  }
}
'@

$src = [System.Drawing.Bitmap]::FromFile("$Root\mobile\assets\images\logo_source.png")
$clear = [KaletaLogo]::RemoveWhite($src)
$src.Dispose()

# Recadrage : logo complet, puis masque seul (premier bloc de lignes opaques, avant le texte).
$left = 0; $right = 0
$rows = [KaletaLogo]::OpaqueRows($clear, [ref]$left, [ref]$right)
$top = [Array]::IndexOf($rows, $true)
$bottom = [Array]::LastIndexOf($rows, $true)
$maskBottom = $top
$gap = 0
for ($y = $top; $y -le $bottom; $y++) {
  if ($rows[$y]) { $maskBottom = $y; $gap = 0 } else { $gap++; if ($gap -ge 12) { break } }
}

function Crop($bmp, [int]$x, [int]$y, [int]$w, [int]$h, [int]$pad) {
  $out = New-Object System.Drawing.Bitmap(($w + 2 * $pad), ($h + 2 * $pad), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle($pad, $pad, $w, $h)), (New-Object System.Drawing.Rectangle($x, $y, $w, $h)), [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose()
  return $out
}

$full = Crop $clear $left $top ($right - $left + 1) ($bottom - $top + 1) 8
$full.Save("$Root\mobile\assets\images\logo_full.png", [System.Drawing.Imaging.ImageFormat]::Png)
$span = [KaletaLogo]::ColumnSpan($clear, $top, $maskBottom)
$mask = Crop $clear $span[0] $top ($span[1] - $span[0] + 1) ($maskBottom - $top + 1) 4
$mask.Save("$Root\mobile\assets\images\logo_mask.png", [System.Drawing.Imaging.ImageFormat]::Png)
$clear.Dispose(); $full.Dispose()

$night = [System.Drawing.Color]::FromArgb(255, 3, 21, 15)
$glow = [System.Drawing.Color]::FromArgb(255, 15, 79, 56)

# Masque centré dans un carré de côté $size, hauteur = $ratio du carré ; fond vert nuit avec halo (ou transparent).
function Save-Icon([int]$size, [double]$ratio, [bool]$background, [bool]$round, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  if ($background) {
    $path2 = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($round) { $path2.AddEllipse(0, 0, $size - 1, $size - 1) } else { $path2.AddRectangle((New-Object System.Drawing.Rectangle(0, 0, $size, $size))) }
    $g.FillPath((New-Object System.Drawing.SolidBrush($night)), $path2)
    # Halo vert derrière le masque (dégradé radial).
    $halo = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = $size * 0.46
    $halo.AddEllipse([single]($size / 2 - $r), [single]($size / 2 - $r), [single](2 * $r), [single](2 * $r))
    $hb = New-Object System.Drawing.Drawing2D.PathGradientBrush($halo)
    $hb.CenterColor = $glow
    $hb.SurroundColors = @($night)
    $g.FillPath($hb, $halo)
    if ($round) {
      $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 212, 181, 102), [single]($size * 0.018))
      $inset = $size * 0.012
      $g.DrawEllipse($pen, [single]$inset, [single]$inset, [single]($size - 2 * $inset), [single]($size - 2 * $inset))
    }
  }
  $h = $size * $ratio
  $w = $h * $mask.Width / $mask.Height
  $g.DrawImage($mask, [single](($size - $w) / 2), [single](($size - $h) / 2), [single]$w, [single]$h)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

# 1) Icône carrée : fond vert nuit, masque sur 78 % de la hauteur.
Save-Icon 1024 0.78 $true $false "$Root\mobile\assets\images\logo.png"
# 2) Icône adaptative : le masque tient dans la zone sûre (cercle de 66 %).
Save-Icon 1024 0.56 $false $false "$Root\mobile\assets\images\logo_foreground.png"
# 3) Pages web : pastille ronde vert nuit, liseré or.
Save-Icon 512 0.7 $true $true "$Root\backend\public\logo.png"

$mask.Dispose()
Write-Output 'logos ok'
