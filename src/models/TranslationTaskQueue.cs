﻿﻿﻿﻿using LiveCaptionsTranslator.utils;
using Serilog;

namespace LiveCaptionsTranslator.models
{
    public class TranslationTaskQueue
    {
        private readonly object _lock = new object();
        private readonly List<TranslationTask> tasks;

        private (string translatedText, bool isChoke) output;
        public (string translatedText, bool isChoke) Output => output;

        // 🔍 New: Queue status monitoring
        public int QueueLength 
        { 
            get 
            { 
                lock (_lock) 
                { 
                    return tasks.Count; 
                } 
            } 
        }
        
        public int ActiveTasksCount
        {
            get
            {
                lock (_lock)
                {
                    return tasks.Count(t => !t.Task.IsCompleted);
                }
            }
        }

        public TranslationTaskQueue()
        {
            tasks = new List<TranslationTask>();
            output = (string.Empty, false);
        }

        public void Enqueue(Func<CancellationToken, Task<(string, bool)>> worker, string originalText)
        {
            var newTranslationTask = new TranslationTask(worker, originalText, new CancellationTokenSource());
            lock (_lock)
            {
                tasks.Add(newTranslationTask);
            }
            // Run `OnTaskCompleted` when successful
            newTranslationTask.Task.ContinueWith(
                task => OnTaskCompleted(newTranslationTask),
                TaskContinuationOptions.OnlyOnRanToCompletion
            );
            // New: Handle Faulted tasks separately to avoid unobserved exceptions
            newTranslationTask.Task.ContinueWith(
                task => OnTaskFaulted(task.Exception, newTranslationTask),
                TaskContinuationOptions.OnlyOnFaulted);
        }

        private async Task OnTaskCompleted(TranslationTask translationTask)
        {
            lock (_lock)
            {
                var index = tasks.IndexOf(translationTask);
                for (int i = 0; i < index; i++)
                    tasks[i].CTS.Cancel();
                for (int i = index; i >= 0; i--)
                    tasks.RemoveAt(i);
            }
            
            output = translationTask.Task.Result;
            var translatedText = output.Item1;
            
            // Log after translation.
            bool isOverwrite = await Translator.IsOverwrite(translationTask.OriginalText);
            if (!isOverwrite)
                await Translator.AddLogCard();
            await Translator.Log(translationTask.OriginalText, translatedText, isOverwrite);
        }

        // New: Faulted task handling
        private void OnTaskFaulted(AggregateException? aggEx, TranslationTask translationTask)
        {
            try
            {
                Log.Error(aggEx, "Translation task faulted. OriginalText: {Text}", translationTask.OriginalText);
            }
            catch { }

            // 🔧 Critical fix: Clean entire queue, cancel all pending tasks to prevent accumulation and blocking
            lock (_lock)
            {
                // Cancel all pending tasks (including failed and queued ones)
                foreach (var task in tasks)
                {
                    try
                    {
                        if (task != translationTask && !task.Task.IsCompleted)
                        {
                            task.CTS.Cancel();
                        }
                    }
                    catch { }
                }
                
                // Clear entire task list
                tasks.Clear();
                
                // Reset output to show error status
                output = ($"[ERROR] Translation queue cleared due to task failure", false);
                
                Log.Warning("Translation queue cleared due to task failure");
            }
        }

        // New: Method to clear queue
        public void Clear()
        {
            lock (_lock)
            {
                // Cancel all pending tasks
                foreach (var task in tasks)
                {
                    try
                    {
                        task.CTS.Cancel();
                    }
                    catch { }
                }
                
                // Clear task list
                tasks.Clear();
                
                // Reset output
                output = (string.Empty, false);
                
                Log.Information("TranslationTaskQueue cleared");
            }
        }
    }

    public class TranslationTask
    {
        public Task<(string, bool)> Task { get; }
        public string OriginalText { get; }
        public CancellationTokenSource CTS { get; }

        public TranslationTask(Func<CancellationToken, Task<(string, bool)>> worker,
            string originalText, CancellationTokenSource cts)
        {
            Task = worker(cts.Token);
            OriginalText = originalText;
            CTS = cts;
        }
    }
}