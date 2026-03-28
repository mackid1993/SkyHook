using System.Linq;
using System.Windows;
using System.Windows.Controls;
using SkyHook.Helpers;
using SkyHook.Models;
using SkyHook.Services;

namespace SkyHook.Views;

public partial class AddRemoteDialog : Window
{
    public AddRemoteDialog()
    {
        InitializeComponent();
        LoadProviders();
        ProviderCombo.SelectionChanged += ProviderCombo_SelectionChanged;
    }

    private void LoadProviders()
    {
        foreach (var (type, name) in RemoteType.AllBackendTypes)
        {
            var item = new ComboBoxItem { Content = name, Tag = type };
            ProviderCombo.Items.Add(item);
        }
        if (ProviderCombo.Items.Count > 0)
            ProviderCombo.SelectedIndex = 0;
    }

    private void ProviderCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProviderCombo.SelectedItem is ComboBoxItem item)
        {
            var type = (string)item.Tag;
            if (RemoteType.OAuthTypes.Contains(type))
                InfoText.Text = "This provider uses browser-based authorization. A browser window will open for you to sign in.";
            else
                InfoText.Text = "You'll be guided through the configuration step by step.";
        }
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        if (string.IsNullOrEmpty(name))
        {
            MessageBox.Show("Please enter a remote name.", "SkyHook");
            return;
        }

        if (RcloneService.Instance.Remotes.Any(r => r.Name == name))
        {
            MessageBox.Show($"A remote named \"{name}\" already exists.", "SkyHook");
            return;
        }

        if (ProviderCombo.SelectedItem is not ComboBoxItem selected)
            return;

        var type = (string)selected.Tag;
        var autoMount = AutoMountCheck.IsChecked == true;

        // Save auto-mount preference
        AppSettings.Instance.SetAutoMount(name, autoMount);

        // Launch interactive setup
        var session = new SetupSession();
        var setupWindow = new SetupView(session) { Owner = this };
        session.Start(RcloneService.Instance.EffectiveRclonePath, name, type);

        var result = setupWindow.ShowDialog();

        if (session.Succeeded)
        {
            RcloneService.Instance.LoadRemotes();
            DialogResult = true;
            Close();
        }
        else
        {
            // Clean up failed remote
            await RcloneService.Instance.RunProcess(RcloneService.Instance.EffectiveRclonePath, new[] { "config", "delete", name }.ToList());
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
