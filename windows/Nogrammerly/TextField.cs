using System.Drawing;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Patterns;
using Nogrammerly.Core;

namespace Nogrammerly;

/// <summary>
/// An editable text control in another app, read and edited through Windows UI Automation
/// (what screen readers use). Offsets are UTF-16 code units, which is how UI Automation counts characters.
/// All calls are cross-process, so use it only from <see cref="SystemWritingAssistant"/>'s worker thread.
/// </summary>
internal sealed class TextField
{
    public AutomationElement Element { get; }
    public int ProcessId { get; }
    private readonly ITextPattern? textPattern;
    private readonly IValuePattern? valuePattern;

    private TextField(AutomationElement element, ITextPattern? text, IValuePattern? value, int processId)
    {
        Element = element; textPattern = text; valuePattern = value; ProcessId = processId;
    }

    /// <summary>True when underlines can be positioned; fields without a text pattern only get the menu.</summary>
    public bool HasLayout => textPattern is not null;

    /// <summary>
    /// Wraps <paramref name="element"/> if it is editable text. Password fields are never read, and read-only
    /// text that still exposes a text pattern (terminal scrollback, web pages, documents in viewers) is skipped.
    /// </summary>
    public static TextField? From(AutomationElement? element)
    {
        if (element is null) return null;
        try
        {
            if (element.Properties.IsPassword.ValueOrDefault) return null;
            var text = element.Patterns.Text.PatternOrDefault;
            var value = element.Patterns.Value.PatternOrDefault;
            var editable = value is not null
                ? !value.IsReadOnly.ValueOrDefault
                : text is not null && element.Properties.ControlType.ValueOrDefault == ControlType.Edit;
            if (!editable || (text is null && value is null)) return null;
            return new TextField(element, text, value, element.Properties.ProcessId.ValueOrDefault);
        }
        catch (Exception)
        {
            return null; // The element vanished or its app stopped responding.
        }
    }

    public bool IsSameElement(TextField other)
    {
        try { return Element.Equals(other.Element); }
        catch (Exception) { return false; }
    }

    public string? ReadText()
    {
        try { return textPattern?.DocumentRange.GetText(-1) ?? valuePattern?.Value.ValueOrDefault; }
        catch (Exception) { return null; }
    }

    /// <summary>The control's on-screen rectangle, in physical pixels.</summary>
    public Rectangle? Frame()
    {
        try
        {
            var frame = Element.Properties.BoundingRectangle.ValueOrDefault;
            return frame.Width > 0 && frame.Height > 0 ? frame : null;
        }
        catch (Exception) { return null; }
    }

    /// <summary>One rectangle per visible line of <paramref name="span"/>; text scrolled out of view has none.</summary>
    public Rectangle[] Bounds(TextSpan span)
    {
        try { return RangeAt(span)?.GetBoundingRectangles() ?? []; }
        catch (Exception) { return []; }
    }

    public bool HasSelectedText()
    {
        try { return textPattern?.GetSelection().FirstOrDefault()?.GetText(1).Length > 0; }
        catch (Exception) { return false; }
    }

    public TextSpan? Selection()
    {
        try
        {
            if (textPattern is null) return null;
            var selection = textPattern.GetSelection().FirstOrDefault();
            if (selection is null) return null;
            var before = textPattern.DocumentRange.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, selection, TextPatternRangeEndpoint.Start);
            return new TextSpan(before.GetText(-1).Length, selection.GetText(-1).Length);
        }
        catch (Exception) { return null; }
    }

    /// <summary>
    /// Replaces <paramref name="span"/> with <paramref name="replacement"/>, keeping the app's undo history:
    /// it selects the span and types over it. Fields that can't select text fall back to setting the whole value.
    /// </summary>
    public bool Replace(TextSpan span, string replacement, string currentText)
    {
        try
        {
            if (RangeAt(span) is { } range)
            {
                range.Select();
                Thread.Sleep(30);
                // Typing goes to whichever window is in front; never type into anything but this field's app.
                return NativeMethods.ForegroundProcessId() == ProcessId && NativeMethods.TypeText(replacement);
            }
            if (valuePattern is not null)
            {
                valuePattern.SetValue(currentText.Remove(span.Start, span.Length).Insert(span.Start, replacement));
                return true;
            }
        }
        catch (Exception) { }
        return false;
    }

    private ITextRange? RangeAt(TextSpan span)
    {
        if (textPattern is null) return null;
        var range = textPattern.DocumentRange.Clone();
        range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
        range.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, span.End);
        range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, span.Start);
        return range;
    }
}
