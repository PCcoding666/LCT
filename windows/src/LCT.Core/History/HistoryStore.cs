using Microsoft.Data.Sqlite;
using LCT.Core.Models;

namespace LCT.Core.History;

/// <summary>
/// Opt-in persistent history in SQLite. Synchronous; the app wraps calls in
/// Task.Run. One connection per operation keeps it trivially thread-safe.
/// </summary>
public sealed class HistoryStore
{
    private readonly string _connectionString;

    public string DatabasePath { get; }

    public HistoryStore(string databasePath)
    {
        DatabasePath = databasePath;
        var directory = Path.GetDirectoryName(databasePath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        _connectionString = new SqliteConnectionStringBuilder { DataSource = databasePath }.ToString();
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS History (
                Id TEXT PRIMARY KEY,
                Timestamp INTEGER NOT NULL,
                SourceText TEXT NOT NULL,
                TranslatedText TEXT NOT NULL,
                TargetLanguage TEXT NOT NULL,
                Source TEXT NOT NULL,
                LatencyMs INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS History_Timestamp ON History(Timestamp);
            """;
        command.ExecuteNonQuery();
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        return connection;
    }

    public void Log(TranslationEntry entry)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "INSERT OR REPLACE INTO History (Id, Timestamp, SourceText, TranslatedText, TargetLanguage, Source, LatencyMs) VALUES ($id, $ts, $src, $dst, $lang, $source, $latency)";
        command.Parameters.AddWithValue("$id", entry.Id.ToString("N"));
        command.Parameters.AddWithValue("$ts", new DateTimeOffset(entry.Timestamp.ToUniversalTime()).ToUnixTimeMilliseconds());
        command.Parameters.AddWithValue("$src", entry.SourceText);
        command.Parameters.AddWithValue("$dst", entry.TranslatedText);
        command.Parameters.AddWithValue("$lang", entry.TargetLanguage);
        command.Parameters.AddWithValue("$source", entry.Source.ToString());
        command.Parameters.AddWithValue("$latency", entry.LatencyMs);
        command.ExecuteNonQuery();
    }

    public IReadOnlyList<TranslationEntry> LoadRecent(int limit = 200)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Id, Timestamp, SourceText, TranslatedText, TargetLanguage, Source, LatencyMs FROM History ORDER BY Timestamp DESC LIMIT $limit";
        command.Parameters.AddWithValue("$limit", limit);
        return Read(command);
    }

    public IReadOnlyList<TranslationEntry> Search(string query, int limit = 500)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Id, Timestamp, SourceText, TranslatedText, TargetLanguage, Source, LatencyMs FROM History WHERE SourceText LIKE $q OR TranslatedText LIKE $q ORDER BY Timestamp DESC LIMIT $limit";
        command.Parameters.AddWithValue("$q", "%" + query.Replace("%", "\\%") + "%");
        command.Parameters.AddWithValue("$limit", limit);
        return Read(command);
    }

    public void Delete(Guid id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM History WHERE Id = $id";
        command.Parameters.AddWithValue("$id", id.ToString("N"));
        command.ExecuteNonQuery();
    }

    public void Clear()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM History";
        command.ExecuteNonQuery();
    }

    public int Count()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM History";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    /// <summary>Drop entries older than retentionDays and everything beyond the newest maxEntries.</summary>
    public int Prune(int retentionDays, int maxEntries, DateTime? now = null)
    {
        var cutoff = new DateTimeOffset((now ?? DateTime.UtcNow).ToUniversalTime()).AddDays(-Math.Max(0, retentionDays)).ToUnixTimeMilliseconds();
        using var connection = Open();
        var removed = 0;
        using (var byAge = connection.CreateCommand())
        {
            byAge.CommandText = "DELETE FROM History WHERE Timestamp < $cutoff";
            byAge.Parameters.AddWithValue("$cutoff", cutoff);
            removed += byAge.ExecuteNonQuery();
        }
        using (var byCount = connection.CreateCommand())
        {
            byCount.CommandText = "DELETE FROM History WHERE Id NOT IN (SELECT Id FROM History ORDER BY Timestamp DESC LIMIT $max)";
            byCount.Parameters.AddWithValue("$max", Math.Max(0, maxEntries));
            removed += byCount.ExecuteNonQuery();
        }
        return removed;
    }

    public string ExportCsv()
    {
        var sb = new System.Text.StringBuilder("Timestamp,Source,SourceText,TranslatedText,TargetLanguage,LatencyMs\n");
        foreach (var entry in LoadRecent(int.MaxValue).Reverse())
        {
            sb.Append(Csv(entry.Timestamp.ToString("yyyy-MM-dd HH:mm:ss"))).Append(',')
              .Append(Csv(entry.Source.Label())).Append(',')
              .Append(Csv(entry.SourceText)).Append(',')
              .Append(Csv(entry.TranslatedText)).Append(',')
              .Append(Csv(entry.TargetLanguage)).Append(',')
              .Append(entry.LatencyMs).Append('\n');
        }
        return sb.ToString();
    }

    private static string Csv(string value) => "\"" + value.Replace("\"", "\"\"") + "\"";

    private static IReadOnlyList<TranslationEntry> Read(SqliteCommand command)
    {
        var entries = new List<TranslationEntry>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var id = Guid.TryParseExact(reader.GetString(0), "N", out var parsed) ? parsed : Guid.NewGuid();
            var timestamp = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(1)).LocalDateTime;
            var source = Enum.TryParse<AudioSource>(reader.GetString(5), out var s) ? s : AudioSource.System;
            entries.Add(new TranslationEntry(id, reader.GetString(2), reader.GetString(3), reader.GetString(4), timestamp, reader.GetInt32(6), source));
        }
        return entries;
    }
}
