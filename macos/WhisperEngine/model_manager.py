"""
Model Manager - Download and manage Whisper/Pyannote models
"""

import logging
import os
import sys
from pathlib import Path
from typing import Dict, Optional, Callable
import hashlib

logger = logging.getLogger('WhisperEngine.model_manager')

# Model information
WHISPER_MODELS = {
    "tiny": {
        "size_mb": 39,
        "memory_gb": 1.0,
        "url": "https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt"
    },
    "base": {
        "size_mb": 74,
        "memory_gb": 1.0,
        "url": "https://openaipublic.azureedge.net/main/whisper/models/ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e/base.pt"
    },
    "small": {
        "size_mb": 244,
        "memory_gb": 2.0,
        "url": "https://openaipublic.azureedge.net/main/whisper/models/9ecf779972d90ba49c06d968637d720dd632c55bbf19d441fb42bf17a411e794/small.pt"
    },
    "medium": {
        "size_mb": 769,
        "memory_gb": 5.0,
        "url": "https://openaipublic.azureedge.net/main/whisper/models/345ae4da62f9b3d59415adc60127b97c714f32e89e936602e85993674d08dcb1/medium.pt"
    },
    "large": {
        "size_mb": 1550,
        "memory_gb": 10.0,
        "url": "https://openaipublic.azureedge.net/main/whisper/models/e5b1a55b89c1367dacf97e3e19bfd829a01529dbfdeefa8caeb59b3f1b81dadb/large-v3.pt"
    }
}


class ModelManager:
    """Manages model downloads and caching"""
    
    def __init__(self, cache_dir: Optional[str] = None):
        """
        Initialize model manager
        
        Args:
            cache_dir: Directory for model cache (default: ~/.cache/whisper)
        """
        if cache_dir:
            self.cache_dir = Path(cache_dir)
        else:
            self.cache_dir = Path.home() / ".cache" / "whisper"
        
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Model cache directory: {self.cache_dir}")
    
    def get_model_info(self, model_name: str) -> Optional[Dict]:
        """Get information about a model"""
        return WHISPER_MODELS.get(model_name)
    
    def is_model_downloaded(self, model_name: str) -> bool:
        """Check if a model is already downloaded"""
        model_path = self.cache_dir / f"{model_name}.pt"
        return model_path.exists()
    
    def get_model_path(self, model_name: str) -> Optional[Path]:
        """Get the path to a downloaded model"""
        model_path = self.cache_dir / f"{model_name}.pt"
        if model_path.exists():
            return model_path
        return None
    
    def download_model(
        self,
        model_name: str,
        progress_callback: Optional[Callable[[int, int], None]] = None
    ) -> bool:
        """
        Download a Whisper model
        
        Args:
            model_name: Name of the model to download
            progress_callback: Optional callback for progress updates (downloaded_bytes, total_bytes)
            
        Returns:
            True if successful
        """
        model_info = self.get_model_info(model_name)
        if not model_info:
            logger.error(f"Unknown model: {model_name}")
            return False
        
        url = model_info["url"]
        model_path = self.cache_dir / f"{model_name}.pt"
        
        if model_path.exists():
            logger.info(f"Model {model_name} already exists")
            return True
        
        logger.info(f"Downloading model {model_name} from {url}")
        
        try:
            import urllib.request
            
            # Create temp file
            temp_path = model_path.with_suffix(".downloading")
            
            def download_progress(block_num, block_size, total_size):
                if progress_callback:
                    downloaded = block_num * block_size
                    progress_callback(downloaded, total_size)
            
            urllib.request.urlretrieve(url, temp_path, reporthook=download_progress)
            
            # Move to final location
            temp_path.rename(model_path)
            
            logger.info(f"Model {model_name} downloaded successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to download model {model_name}: {e}")
            # Clean up temp file
            temp_path = model_path.with_suffix(".downloading")
            if temp_path.exists():
                temp_path.unlink()
            return False
    
    def delete_model(self, model_name: str) -> bool:
        """Delete a downloaded model"""
        model_path = self.cache_dir / f"{model_name}.pt"
        if model_path.exists():
            try:
                model_path.unlink()
                logger.info(f"Model {model_name} deleted")
                return True
            except Exception as e:
                logger.error(f"Failed to delete model {model_name}: {e}")
                return False
        return True
    
    def list_downloaded_models(self) -> list:
        """List all downloaded models"""
        models = []
        for model_name in WHISPER_MODELS:
            if self.is_model_downloaded(model_name):
                models.append(model_name)
        return models
    
    def get_total_cache_size(self) -> int:
        """Get total size of cached models in bytes"""
        total = 0
        for f in self.cache_dir.glob("*.pt"):
            total += f.stat().st_size
        return total
    
    def clear_cache(self) -> bool:
        """Clear all cached models"""
        try:
            for f in self.cache_dir.glob("*.pt"):
                f.unlink()
            logger.info("Model cache cleared")
            return True
        except Exception as e:
            logger.error(f"Failed to clear cache: {e}")
            return False


def check_pyannote_access(hf_token: str) -> bool:
    """
    Check if Hugging Face token has access to Pyannote models
    
    Args:
        hf_token: Hugging Face authentication token
        
    Returns:
        True if token has access
    """
    try:
        from huggingface_hub import HfApi
        
        api = HfApi()
        
        # Try to get model info
        model_info = api.model_info(
            "pyannote/speaker-diarization-3.1",
            token=hf_token
        )
        
        return model_info is not None
        
    except Exception as e:
        logger.error(f"Failed to check Pyannote access: {e}")
        return False


def setup_environment():
    """Setup environment for model downloads"""
    # Disable SSL verification issues on macOS
    import ssl
    ssl._create_default_https_context = ssl._create_unverified_context
    
    # Set cache directories
    os.environ.setdefault("HF_HOME", str(Path.home() / ".cache" / "huggingface"))
    os.environ.setdefault("TORCH_HOME", str(Path.home() / ".cache" / "torch"))


if __name__ == "__main__":
    # CLI for model management
    import argparse
    
    logging.basicConfig(level=logging.INFO)
    setup_environment()
    
    parser = argparse.ArgumentParser(description="Whisper Model Manager")
    subparsers = parser.add_subparsers(dest="command")
    
    # List command
    list_parser = subparsers.add_parser("list", help="List available models")
    list_parser.add_argument("--downloaded", action="store_true", help="Show only downloaded models")
    
    # Download command
    download_parser = subparsers.add_parser("download", help="Download a model")
    download_parser.add_argument("model", choices=list(WHISPER_MODELS.keys()), help="Model to download")
    
    # Delete command
    delete_parser = subparsers.add_parser("delete", help="Delete a model")
    delete_parser.add_argument("model", choices=list(WHISPER_MODELS.keys()), help="Model to delete")
    
    # Clear command
    clear_parser = subparsers.add_parser("clear", help="Clear all cached models")
    
    args = parser.parse_args()
    manager = ModelManager()
    
    if args.command == "list":
        print("\nAvailable Whisper Models:")
        print("-" * 60)
        for name, info in WHISPER_MODELS.items():
            downloaded = "✓" if manager.is_model_downloaded(name) else " "
            print(f"  [{downloaded}] {name:10} - {info['size_mb']:5} MB, {info['memory_gb']:.1f} GB RAM")
        print()
        print(f"Downloaded models: {', '.join(manager.list_downloaded_models()) or 'None'}")
        print(f"Total cache size: {manager.get_total_cache_size() / 1024 / 1024:.1f} MB")
        
    elif args.command == "download":
        def progress(downloaded, total):
            pct = (downloaded / total) * 100 if total > 0 else 0
            print(f"\rDownloading: {pct:.1f}% ({downloaded / 1024 / 1024:.1f} MB)", end="", flush=True)
        
        print(f"Downloading {args.model}...")
        if manager.download_model(args.model, progress_callback=progress):
            print("\nDone!")
        else:
            print("\nFailed!")
            sys.exit(1)
            
    elif args.command == "delete":
        if manager.delete_model(args.model):
            print(f"Model {args.model} deleted")
        else:
            print(f"Failed to delete {args.model}")
            sys.exit(1)
            
    elif args.command == "clear":
        if manager.clear_cache():
            print("Cache cleared")
        else:
            print("Failed to clear cache")
            sys.exit(1)
    else:
        parser.print_help()
