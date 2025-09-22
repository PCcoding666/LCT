**Product Name:** LiveCaptions Translator (Dell Local Edition)

**1. Overview**
This document outlines the requirements for the Dell Local Edition of the LiveCaptions Translator. The goal is to create a streamlined, robust, and easy-to-deploy version of the application specifically for Dell machines, relying exclusively on local inference via the Ollama engine.

**2. Core Principle**
The application will be refactored to remove all dependencies on external, web-based translation APIs. The core focus is on local, private, and efficient real-time translation.

**3. Key Requirements**

*   **3.1. Exclusive Translation Engine:**
    *   Ollama will be the sole translation engine.
    *   All other integrated APIs (Google Translate, DeepL, OpenRouter, etc.) must be completely removed from the codebase.

*   **3.2. User Interface (UI) Modifications:**
    *   **3.2.1. Settings Page:** The UI for selecting a translation service (e.g., a ComboBox or dropdown menu) on the settings page must be removed. The application will default to the Ollama settings view.
    *   **3.2.2. Branding:** The application's welcome/splash screen must prominently feature the Dell logo. The existing `dell_logo.png` in the project resources should be used.

*   **3.3. Configuration:**
    *   **3.3.1. Ollama Settings:** All user-configurable settings for Ollama must be retained. This includes, but is not limited to:
        *   API Endpoint URL
        *   Model Name
        *   System Prompt
        *   All other parameters present in the original Ollama configuration section.

**4. Non-functional Requirements**
*   The application should remain lightweight and efficient.
*   The removal of web APIs should result in a smaller application footprint and reduced complexity.