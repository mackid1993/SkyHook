using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace SkyHook.Models;

public class Remote
{
    [JsonPropertyName("id")]
    public Guid Id { get; set; } = Guid.NewGuid();

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("config")]
    public Dictionary<string, string> Config { get; set; } = new();

    [JsonPropertyName("driveLetter")]
    public string DriveLetter { get; set; } = "Z:";

    [JsonPropertyName("remotePath")]
    public string RemotePath { get; set; } = string.Empty;

    [JsonPropertyName("autoMount")]
    public bool AutoMount { get; set; }

    [JsonIgnore]
    public string DisplayType => RemoteType.DisplayName(Type);

    [JsonIgnore]
    public string TypeIcon => RemoteType.Icon(Type);
}
