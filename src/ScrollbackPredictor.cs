using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;

namespace ScrollbackPredictor
{
    public class ScrollbackPredictor : ICommandPredictor
    {
        private readonly Guid _id = Guid.Parse("f3b3e7a0-6c1a-4e2d-9f5b-8a7c3d2e1f00");

        public Guid Id => _id;
        public string Name => "Scrollback";
        public string Description => "Suggests completions from previous command output.";

        public SuggestionPackage GetSuggestion(
            PredictionClient client,
            PredictionContext context,
            CancellationToken cancellationToken)
        {
            var input = context.InputAst.Extent.Text;
            if (string.IsNullOrWhiteSpace(input))
                return default;

            var lastToken = ExtractLastToken(input);
            if (string.IsNullOrEmpty(lastToken) || lastToken.Length < 2)
                return default;

            var matches = ScrollbackIndex.FindMatches(lastToken);
            if (matches.Count == 0)
                return default;

            var suggestions = new List<PredictiveSuggestion>();
            foreach (var match in matches)
            {
                // Replace the last token in the input with the match
                var suggestion = input.Substring(0, input.Length - lastToken.Length) + match;
                suggestions.Add(new PredictiveSuggestion(suggestion));
            }

            return new SuggestionPackage(suggestions);
        }

        public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback) => false;

        public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrIndex) { }

        public void OnSuggestionAccepted(PredictionClient client, uint session, string acceptedSuggestion) { }

        public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }

        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }

        private static string ExtractLastToken(string input)
        {
            // Walk backwards from end to find the start of the last token
            var i = input.Length - 1;

            // Skip trailing whitespace — if input ends with space, no partial token to complete
            if (i >= 0 && char.IsWhiteSpace(input[i]))
                return string.Empty;

            while (i >= 0 && !IsTokenBoundary(input[i]))
                i--;

            return input.Substring(i + 1);
        }

        private static bool IsTokenBoundary(char c)
        {
            return char.IsWhiteSpace(c) || c == '|' || c == ';' || c == '(' || c == ')';
        }
    }
}
