#!/bin/bash
# LCT for macOS - Setup Script
# This script sets up the development environment

set -e

echo "======================================"
echo "  LCT for macOS - Environment Setup"
echo "======================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check macOS version
echo "Checking macOS version..."
OS_VERSION=$(sw_vers -productVersion)
MAJOR_VERSION=$(echo $OS_VERSION | cut -d. -f1)

if [ "$MAJOR_VERSION" -lt "15" ]; then
    echo -e "${RED}Error: macOS 15 (Sequoia) or later is required${NC}"
    echo "Current version: $OS_VERSION"
    exit 1
fi
echo -e "${GREEN}✓ macOS $OS_VERSION${NC}"

# Check Xcode
echo ""
echo "Checking Xcode..."
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Error: Xcode is not installed${NC}"
    echo "Please install Xcode from the App Store"
    exit 1
fi
XCODE_VERSION=$(xcodebuild -version | head -1)
echo -e "${GREEN}✓ $XCODE_VERSION${NC}"

# Check Python
echo ""
echo "Checking Python..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version)
    echo -e "${GREEN}✓ $PYTHON_VERSION${NC}"
    PYTHON_PATH=$(which python3)
else
    echo -e "${YELLOW}Warning: Python 3 not found${NC}"
    echo "Python is required for Whisper speech recognition"
    echo "Install via: brew install python@3.11"
    PYTHON_PATH=""
fi

# Check pip
echo ""
echo "Checking pip..."
if command -v pip3 &> /dev/null; then
    PIP_VERSION=$(pip3 --version | cut -d' ' -f1-2)
    echo -e "${GREEN}✓ $PIP_VERSION${NC}"
else
    echo -e "${YELLOW}Warning: pip not found${NC}"
fi

# Check Ollama
echo ""
echo "Checking Ollama..."
if command -v ollama &> /dev/null; then
    OLLAMA_VERSION=$(ollama --version 2>&1 | head -1)
    echo -e "${GREEN}✓ Ollama installed${NC}"
    
    # Check if Ollama is running
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Ollama is running${NC}"
    else
        echo -e "${YELLOW}! Ollama is not running${NC}"
        echo "  Start with: ollama serve"
    fi
else
    echo -e "${YELLOW}Warning: Ollama not installed${NC}"
    echo "Install via: brew install ollama"
    echo "Or download from: https://ollama.ai"
fi

# Setup Python environment
echo ""
echo "======================================"
echo "Setting up Python environment..."
echo "======================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_DIR="$SCRIPT_DIR/../WhisperEngine"

if [ -d "$WHISPER_DIR" ]; then
    cd "$WHISPER_DIR"
    
    # Create virtual environment
    if [ ! -d "venv" ]; then
        echo "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate and install dependencies
    echo "Installing Python dependencies..."
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
    deactivate
    
    echo -e "${GREEN}✓ Python environment ready${NC}"
else
    echo -e "${YELLOW}Warning: WhisperEngine directory not found${NC}"
fi

# Download default Whisper model
echo ""
echo "======================================"
echo "Downloading Whisper model..."
echo "======================================"

if [ -d "$WHISPER_DIR" ]; then
    cd "$WHISPER_DIR"
    source venv/bin/activate
    python model_manager.py download base
    deactivate
    echo -e "${GREEN}✓ Whisper base model downloaded${NC}"
fi

# Summary
echo ""
echo "======================================"
echo "  Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Open macos/LCTMac in Xcode"
echo "2. Build and run the app"
echo "3. Grant screen capture and microphone permissions when prompted"
echo ""
echo "To start the WhisperEngine manually:"
echo "  cd $WHISPER_DIR"
echo "  source venv/bin/activate"
echo "  python main.py --model base"
echo ""
echo "To pull a translation model in Ollama:"
echo "  ollama pull qwen3.5:4b-mlx"
echo ""
