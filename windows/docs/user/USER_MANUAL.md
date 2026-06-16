
# User Manual

This document provides instructions for end-users of the LiveCaptions Translator application.

## 1. Starting the Application

To start the application, you can run the installer `DellLiveCaptionsTranslator-LocalEdition-Setup.exe` if you have it.

If you are running from the source code or a built version, you can start the application by running the `LiveCaptionsTranslator.exe` file located in the `bin\Release\net8.0-windows\win-x64\publish` directory.

Alternatively, you can use the startup script located at `scripts\deployment\startup.bat` which also ensures the required Ollama service is running.

## 2. Configuring Languages

Language settings can be configured within the application on the **Settings** page.

### Setting Source Language
The application automatically captures text from the Windows Live Captions feature. The source language is determined by your Windows system's Live Captions settings. Please configure the language you want to be transcribed there.

### Setting Target Language
1.  Navigate to the **Settings** page in the application.
2.  Find the **Target Language** dropdown menu.
3.  Select your desired target language from the list. The list is populated with languages supported by the Ollama translation service.
4.  If your desired language is not in the list, you can type it into the box.
5.  The setting is saved automatically when you select or enter a language.

## 3. Exporting Translation History

The application keeps a log of all translations. You can export this history for your records.

1.  Navigate to the **History** page in the application.
2.  Click the **Export** button.
3.  A "Save File" dialog will appear. Choose a location and a file name for your export. The default format is CSV (`.csv`).
4.  Click **Save**. A confirmation message will appear once the file has been saved successfully.
5.  The exported data is stored in the `translation_history.db` file in the application's root directory.

