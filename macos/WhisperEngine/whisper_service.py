"""
WhisperService - Speech-to-Text using OpenAI Whisper
"""

import logging
import tempfile
import os
from pathlib import Path
from typing import Dict, List, Optional, Any
import numpy as np

logger = logging.getLogger('WhisperEngine.whisper')

class WhisperService:
    """Service for transcribing audio using Whisper"""
    
    def __init__(self, model_size: str = "base", device: str = "auto"):
        """
        Initialize Whisper service
        
        Args:
            model_size: Whisper model size (tiny, base, small, medium, large)
            device: Compute device (auto, cpu, cuda, mps)
        """
        self.model_size = model_size
        self.device = self._determine_device(device)
        self.model = None
        
        logger.info(f"Initializing Whisper with model '{model_size}' on device '{self.device}'")
        self._load_model()
    
    def _determine_device(self, device: str) -> str:
        """Determine the best available device"""
        if device != "auto":
            return device
        
        try:
            import torch
            if torch.cuda.is_available():
                return "cuda"
            elif torch.backends.mps.is_available():
                return "mps"  # Apple Silicon
            else:
                return "cpu"
        except ImportError:
            return "cpu"
    
    def _load_model(self):
        """Load the Whisper model"""
        try:
            import whisper
            logger.info(f"Loading Whisper model: {self.model_size}")
            
            self.model = whisper.load_model(
                self.model_size,
                device=self.device
            )
            
            logger.info(f"Whisper model loaded successfully on {self.device}")
        except Exception as e:
            logger.error(f"Failed to load Whisper model: {e}")
            raise
    
    def transcribe(
        self,
        audio_data: np.ndarray,
        sample_rate: int = 16000,
        language: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Transcribe audio data
        
        Args:
            audio_data: Audio samples as numpy array (float32, mono)
            sample_rate: Sample rate of audio (default 16000)
            language: Optional language hint
            
        Returns:
            Dictionary with transcription results
        """
        if self.model is None:
            raise RuntimeError("Whisper model not loaded")
        
        try:
            # Ensure audio is float32 and normalized
            if audio_data.dtype != np.float32:
                audio_data = audio_data.astype(np.float32)
            
            # Normalize if needed
            max_val = np.abs(audio_data).max()
            if max_val > 1.0:
                audio_data = audio_data / max_val
            
            # Resample if needed (Whisper expects 16kHz)
            if sample_rate != 16000:
                audio_data = self._resample(audio_data, sample_rate, 16000)
            
            # Transcribe
            options = {
                "fp16": self.device == "cuda",
                "language": language,
                "task": "transcribe"
            }
            
            result = self.model.transcribe(audio_data, **options)
            
            # Format result
            segments = []
            for seg in result.get("segments", []):
                segments.append({
                    "text": seg["text"].strip(),
                    "start": seg["start"],
                    "end": seg["end"],
                    "confidence": seg.get("avg_logprob", 0)
                })
            
            return {
                "success": True,
                "text": result.get("text", "").strip(),
                "language": result.get("language", "unknown"),
                "segments": segments
            }
            
        except Exception as e:
            logger.error(f"Transcription failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "text": "",
                "segments": []
            }
    
    def transcribe_file(self, audio_path: str, language: Optional[str] = None) -> Dict[str, Any]:
        """
        Transcribe an audio file
        
        Args:
            audio_path: Path to audio file
            language: Optional language hint
            
        Returns:
            Dictionary with transcription results
        """
        if self.model is None:
            raise RuntimeError("Whisper model not loaded")
        
        try:
            options = {
                "fp16": self.device == "cuda",
                "language": language,
                "task": "transcribe"
            }
            
            result = self.model.transcribe(audio_path, **options)
            
            segments = []
            for seg in result.get("segments", []):
                segments.append({
                    "text": seg["text"].strip(),
                    "start": seg["start"],
                    "end": seg["end"],
                    "confidence": seg.get("avg_logprob", 0)
                })
            
            return {
                "success": True,
                "text": result.get("text", "").strip(),
                "language": result.get("language", "unknown"),
                "segments": segments
            }
            
        except Exception as e:
            logger.error(f"File transcription failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "text": "",
                "segments": []
            }
    
    def _resample(self, audio: np.ndarray, orig_sr: int, target_sr: int) -> np.ndarray:
        """Resample audio to target sample rate"""
        try:
            import librosa
            return librosa.resample(audio, orig_sr=orig_sr, target_sr=target_sr)
        except ImportError:
            # Simple linear interpolation fallback
            ratio = target_sr / orig_sr
            new_length = int(len(audio) * ratio)
            indices = np.linspace(0, len(audio) - 1, new_length)
            return np.interp(indices, np.arange(len(audio)), audio)
    
    def get_model_info(self) -> Dict[str, Any]:
        """Get information about the loaded model"""
        return {
            "model_size": self.model_size,
            "device": self.device,
            "loaded": self.model is not None
        }
    
    def unload(self):
        """Unload the model to free memory"""
        if self.model is not None:
            del self.model
            self.model = None
            
            # Force garbage collection
            import gc
            gc.collect()
            
            # Clear CUDA cache if applicable
            try:
                import torch
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except:
                pass
            
            logger.info("Whisper model unloaded")
