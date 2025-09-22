# LiveCaptions Translator

## Introduction

LiveCaptions Translator is a desktop application designed to provide real-time translation of your system's Live Captions. It captures the original caption text, translates it into your desired language, and displays both the original and translated text in a clean, intuitive interface. This tool is perfect for users who want to understand foreign language content, attend international meetings, or simply make live audio more accessible.

## Key Features

- **Real-time Translation:** Instantly translates system Live Captions.
- **Multiple API Support:** Allows you to choose from various translation service providers (e.g., OpenAI).
- **Translation History:** Automatically saves all translations. You can browse, search, filter, export, and manage your history.
- **Highly Configurable:** Offers a wide range of settings to customize the user experience, including API settings, target language, UI behavior, and performance tuning.
- **User-Friendly Interface:** Features a simple navigation sidebar, clear controls, and two main viewing modes (standard and compact).
- **Window Management:** Includes an "Always on Top" feature to keep the translator visible and accessible.

## Screenshots

### Home (Real-time Translation View)
*(Image of the main translation interface)*
![Home View](images/preview.png)

### Settings View
*(Image of the settings grid)*
![Settings View](images/speech_recognition.png)

### History View
*(Image of the translation history table)*
![History View](images/history.png)

## How to Use

The application is organized into four main sections, accessible via the left sidebar.

### Main Window Controls

The top header contains global controls for the application window:
- **Pause/Resume Button:** Start or stop the real-time translation process.
- **Compact Mode Button:** Switch to a smaller, minimalist UI that only shows the translated text.
- **Pin/Always on Top Button:** Keep the application window on top of all other windows.

### 1. Home (Real-time Translation)

This is the main screen where the magic happens. It features a two-panel layout:
- **Top Panel:** Displays the original text captured from your system's Live Captions.
- **Bottom Panel:** Displays the translated text in real-time.

### 2. Settings

This screen allows you to configure the application to your needs. See the detailed Configuration section below for more information.

### 3. History

This screen provides a comprehensive view of your past translations.
- **Pagination:** Navigate through pages of your translation history.
- **Items per Page:** Choose how many translations to display on a single page.
- **Search Bar:** Quickly find specific translations by searching for keywords.
- **Action Buttons:**
    - **Download:** Export your translation history to a file.
    - **Delete:** Remove selected entries from the history.
    - **Reset:** Completely clear all saved translation history.

### 4. Info

This screen displays information about the application, such as its version number and other relevant details.

## Configuration

You can customize the following options in the **Settings** view:

- **LiveCaptions:** Controls the visibility of the original caption text in the Home view.
  - **Show:** Displays both the original and translated text.
  - **Hide:** Displays only the translated text.
- **Translate API:** Select your preferred translation service provider from the dropdown menu.
- **API Setting:** Opens a dialog to enter your credentials (e.g., API Key, Secret) for the selected translation service.
- **Log Cards:** Determines the number of recent translation "cards" or entries displayed or cached.
- **API Interval:** Adjust the slider to set the time delay (in milliseconds) between translation API calls. A higher value can reduce costs and lower API request frequency, while a lower value provides faster translations.
- **Target Language:** Select the language you want the captions to be translated into.
- **Show Latency:** A toggle switch. When enabled, it displays the network latency (in milliseconds) for each translation, helping you gauge performance.
- **Overlay Sentences:** Controls how many sentences are displayed or grouped in the overlay/compact view.