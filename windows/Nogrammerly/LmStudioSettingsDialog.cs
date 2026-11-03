namespace Nogrammerly;

/// <summary>
/// Edits the LM Studio base URL and model ID and can test the server by listing /v1/models.
/// The only network call happens when the user presses Test; OK validates and saves, even
/// while the server is offline. Choosing a model ID from the discovered list is optional typing.
/// </summary>
internal sealed class LmStudioSettingsDialog : Form
{
    private readonly LmStudioWriter lmStudio;
    private readonly Func<AppSettings, bool> save;
    private readonly AiProvider provider;
    private CancellationTokenSource? probeCancellation;
    private readonly TextBox url = new() { Bounds = new Rectangle(150, 12, 340, 26) };
    private readonly TextBox model = new() { Bounds = new Rectangle(150, 44, 340, 26) };
    private readonly ComboBox discovered = new() { Bounds = new Rectangle(150, 112, 340, 26), DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Button test = new() { Text = "Test / discover models", Bounds = new Rectangle(150, 146, 170, 30) };
    private readonly Button ok = new() { Text = "OK", Bounds = new Rectangle(314, 246, 86, 30), DialogResult = DialogResult.OK };
    private readonly Button cancel = new() { Text = "Cancel", Bounds = new Rectangle(404, 246, 86, 30), DialogResult = DialogResult.Cancel };
    private readonly Label status = new() { Bounds = new Rectangle(150, 182, 340, 56), AutoSize = false };

    public LmStudioSettingsDialog(AppSettings current, LmStudioWriter lmStudio, Func<AppSettings, bool> save)
    {
        this.lmStudio = lmStudio;
        this.save = save;
        provider = current.Provider;
        FormClosed += (_, _) => probeCancellation?.Cancel();
        url.Text = current.BaseUrl;
        model.Text = current.ModelId;

        Controls.Add(new Label { Text = "Base URL:", Bounds = new Rectangle(12, 15, 130, 20) });
        Controls.Add(new Label { Text = "Model ID:", Bounds = new Rectangle(12, 47, 130, 20) });
        Controls.Add(new Label { Text = "Discovered models:", Bounds = new Rectangle(12, 115, 134, 20) });
        Controls.Add(new Label
        {
            Text = "⚠ With LM Studio, the text being checked or rewritten is sent over your network to this address. "
                + "Over plain HTTP it is unencrypted on your LAN; use HTTPS if your server supports it.",
            Bounds = new Rectangle(12, 76, 480, 34), AutoSize = false,
        });
        Controls.Add(url);
        Controls.Add(model);
        Controls.Add(discovered);
        Controls.Add(test);
        Controls.Add(status);
        Controls.Add(ok);
        Controls.Add(cancel);
        discovered.SelectedIndexChanged += (_, _) => model.Text = discovered.SelectedItem as string ?? model.Text;
        test.Click += Test_Click;
        ok.Click += Ok_Click;

        Text = "LM Studio settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true; // the tray has no main window to own this
        ClientSize = new Size(504, 288);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    private AppSettings Draft => new(provider, url.Text.Trim(), model.Text.Trim());

    private async void Test_Click(object? sender, EventArgs e)
    {
        var draft = Draft;
        if (!draft.TryValidate(out var error)) { status.Text = error; return; }
        test.Enabled = false;
        status.Text = "Contacting server…";
        probeCancellation = new CancellationTokenSource();
        var ids = await Task.Run(() => lmStudio.ModelsAsync(draft, probeCancellation.Token));
        probeCancellation.Dispose();
        probeCancellation = null;
        if (IsDisposed || Disposing || !Visible) return;
        test.Enabled = true;
        discovered.Items.Clear();
        if (ids.Count > 0)
        {
            discovered.Items.AddRange(ids.Cast<object>().ToArray());
            status.Text = $"Found {ids.Count} model{(ids.Count == 1 ? "" : "s")}. Pick one or type the ID.";
        }
        else status.Text = "Couldn't list models: " + (lmStudio.LastError ?? "no models returned");
    }

    private void Ok_Click(object? sender, EventArgs e)
    {
        var draft = Draft;
        if (!draft.TryValidate(out var error))
        {
            status.Text = error;
            DialogResult = DialogResult.None; // keep the dialog open
            return;
        }
        if (!save(draft)) { DialogResult = DialogResult.None; return; }
        status.Text = "Saved.";
    }
}
