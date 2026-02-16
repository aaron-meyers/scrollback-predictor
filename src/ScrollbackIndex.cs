using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace ScrollbackPredictor
{
    public static class ScrollbackIndex
    {
        private static readonly ConcurrentDictionary<string, byte> _tokens = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        private static readonly ConcurrentQueue<string> _insertionOrder = new ConcurrentQueue<string>();
        private const int MaxTokens = 10000;

        /// <summary>
        /// Extract and index interesting tokens from a line of output.
        /// </summary>
        public static void AddLine(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return;

            // Split on whitespace and common table separators
            var parts = line.Split(new[] { ' ', '\t', '|', ',', ';', '(', ')', '[', ']', '{', '}', '"', '\'' },
                StringSplitOptions.RemoveEmptyEntries);

            foreach (var part in parts)
            {
                var token = part.Trim();
                // Keep tokens that look like identifiers, paths, or package IDs (3+ chars)
                if (token.Length >= 3 && IsInterestingToken(token))
                {
                    if (_tokens.TryAdd(token, 0))
                    {
                        _insertionOrder.Enqueue(token);
                        Evict();
                    }
                }
            }
        }

        /// <summary>
        /// Find tokens matching the given prefix.
        /// </summary>
        public static List<string> FindMatches(string prefix, int maxResults = 20)
        {
            return _tokens.Keys
                .Where(t => t.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                         && !t.Equals(prefix, StringComparison.OrdinalIgnoreCase))
                .OrderBy(t => t, StringComparer.OrdinalIgnoreCase)
                .Take(maxResults)
                .ToList();
        }

        /// <summary>
        /// Clear all indexed tokens.
        /// </summary>
        public static void Clear()
        {
            _tokens.Clear();
            while (_insertionOrder.TryDequeue(out _)) { }
        }

        public static int Count => _tokens.Count;

        private static void Evict()
        {
            while (_tokens.Count > MaxTokens && _insertionOrder.TryDequeue(out var oldest))
            {
                _tokens.TryRemove(oldest, out _);
            }
        }

        private static bool IsInterestingToken(string token)
        {
            // Must start with a letter, digit, dot, or path separator
            var first = token[0];
            if (!char.IsLetterOrDigit(first) && first != '.' && first != '/' && first != '\\' && first != '_' && first != '-')
                return false;

            // Allow word chars plus dots, hyphens, slashes, backslashes, colons (paths/package IDs)
            foreach (var c in token)
            {
                if (!char.IsLetterOrDigit(c) && c != '.' && c != '-' && c != '_' && c != '/' && c != '\\' && c != ':' && c != '@')
                    return false;
            }

            // Reject tokens that are purely numeric
            bool allDigits = true;
            foreach (var c in token)
            {
                if (!char.IsDigit(c) && c != '.')
                {
                    allDigits = false;
                    break;
                }
            }

            return !allDigits;
        }
    }
}
