using System.Drawing;
using System.Drawing.Drawing2D;
using Nogrammerly.Core;
using static Nogrammerly.NativeMethods;

namespace Nogrammerly;

/// <summary>
/// A borderless, always-on-top window that never takes focus, so the app being typed in keeps its cursor and selection.
/// Coordinates are physical pixels; the window ignores DPI changes so positions from UI Automation stay exact.
/// </summary>
internal class FloatingWindow : Form
{
    protected FloatingWindow()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        TopMost = true;
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_DPICHANGED) return;
        base.WndProc(ref m);
    }

    protected void ShowAt(Rectangle bounds)
    {
        Bounds = bounds;
        if (!Visible) Show();
    }
}

/// <summary>Transparent, click-through window that draws coloured underlines over another app's text.</summary>
internal sealed class UnderlineOverlay : FloatingWindow
{
    private static readonly Color Key = Color.FromArgb(255, 0, 255);
    private (Rectangle Rect, Color Color)[] lines = [];

    public UnderlineOverlay()
    {
        BackColor = Key;
        TransparencyKey = Key;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT;
            return cp;
        }
    }

    public void ShowMarks(IReadOnlyList<Mark> marks)
    {
        var all = marks.SelectMany(m => m.Rects.Select(r => (Rect: r, Color: Theme.Color(m.Suggestion.Kind)))).ToArray();
        if (all.Length == 0) { Hide(); return; }
        var area = all.Select(l => l.Rect).Aggregate(Rectangle.Union);
        area.Inflate(4, 4);
        lines = all.Select(l => (new Rectangle(l.Rect.X - area.X, l.Rect.Y - area.Y, l.Rect.Width, l.Rect.Height), l.Color)).ToArray();
        ShowAt(area);
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // No anti-aliasing: blended edge pixels would not match the transparency key and show as a pink fringe.
        foreach (var (rect, color) in lines)
        {
            using var pen = new Pen(color, Math.Max(2, rect.Height / 9));
            e.Graphics.DrawLine(pen, rect.Left, rect.Bottom, rect.Right, rect.Bottom);
        }
    }
}

/// <summary>Grammarly-style round button pinned to the bottom-right corner of the field being edited.</summary>
internal sealed class FieldButton : FloatingWindow
{
    private const int BaseSize = 26;
    private int issues;

    public FieldButton(Action onClick)
    {
        Cursor = Cursors.Hand;
        MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) onClick(); };
        var tip = new ToolTip();
        tip.SetToolTip(this, "Nogrammerly: suggestions and rewrites");
    }

    /// <summary><paramref name="field"/> is in physical screen pixels.</summary>
    public void ShowFor(Rectangle field, int issueCount)
    {
        var dpi = GetDpiForWindow(GetForegroundWindow());
        var size = BaseSize * (int)(dpi == 0 ? 96 : dpi) / 96;
        var screen = Screen.FromRectangle(field).WorkingArea;
        var x = Math.Clamp(field.Right - size - size / 4, screen.Left, screen.Right - size);
        var y = Math.Clamp(field.Bottom - size - size / 4, screen.Top, screen.Bottom - size);
        if (issueCount != issues || Width != size) { issues = issueCount; Invalidate(); }
        if (Width != size)
        {
            using var path = new GraphicsPath();
            path.AddEllipse(0, 0, size, size);
            Region = new Region(path);
        }
        ShowAt(new Rectangle(x, y, size, size));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using var fill = new SolidBrush(issues == 0 ? Theme.Green : Theme.Red);
        g.FillEllipse(fill, 0, 0, Width - 1, Height - 1);
        var label = issues == 0 ? "✦" : Math.Min(issues, 99).ToString();
        using var font = new Font("Segoe UI", Height * (issues == 0 ? 0.42f : 0.38f), FontStyle.Bold, GraphicsUnit.Pixel);
        TextRenderer.DrawText(g, label, font, ClientRectangle, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// <summary>
/// An invisible window that owns popup menus. Windows only closes a menu on an outside click when the menu's
/// app is in front, so it comes to the front while a menu is open and then hands focus back to the app.
/// </summary>
internal sealed class MenuHost : Form
{
    private IntPtr previous;

    public MenuHost()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(-32000, -32000, 1, 1);
        Opacity = 0;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    public void Pop(ContextMenuStrip menu, Point at)
    {
        previous = GetForegroundWindow();
        if (!Visible) Show();
        ForceForeground(Handle);
        menu.Closed += (_, _) => { if (previous != IntPtr.Zero) SetForegroundWindow(previous); };
        menu.Show(this, PointToClient(at));
    }
}

internal static class Theme
{
    public static readonly Color Red = System.Drawing.Color.FromArgb(215, 0, 21);
    public static readonly Color Green = System.Drawing.Color.FromArgb(36, 138, 61);

    public static Color Color(SuggestionKind kind) => kind switch
    {
        SuggestionKind.Correctness => Red,
        SuggestionKind.Clarity => System.Drawing.Color.FromArgb(0, 64, 221),
        SuggestionKind.Delivery => System.Drawing.Color.FromArgb(137, 68, 171),
        _ => System.Drawing.Color.FromArgb(201, 52, 0),
    };
}
