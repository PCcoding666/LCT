"""
DiarizationService - Speaker Diarization using Pyannote
"""

import logging
import tempfile
import os
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple
import numpy as np

logger = logging.getLogger('WhisperEngine.diarization')

class DiarizationService:
    """Service for speaker diarization using Pyannote"""
    
    def __init__(self, hf_token: str, device: str = "auto"):
        """
        Initialize diarization service
        
        Args:
            hf_token: Hugging Face authentication token
            device: Compute device (auto, cpu, cuda, mps)
        """
        self.hf_token = hf_token
        self.device = self._determine_device(device)
        self.pipeline = None
        
        logger.info(f"Initializing Pyannote diarization on device '{self.device}'")
        self._load_pipeline()
    
    def _determine_device(self, device: str) -> str:
        """Determine the best available device"""
        if device != "auto":
            return device
        
        try:
            import torch
            if torch.cuda.is_available():
                return "cuda"
            elif torch.backends.mps.is_available():
                # MPS support is limited in pyannote
                return "cpu"  # Fall back to CPU for pyannote
            else:
                return "cpu"
        except ImportError:
            return "cpu"
    
    def _load_pipeline(self):
        """Load the Pyannote diarization pipeline"""
        try:
            from pyannote.audio import Pipeline
            import torch
            
            logger.info("Loading Pyannote speaker diarization pipeline...")
            
            self.pipeline = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=self.hf_token
            )
            
            # Move to device
            if self.device == "cuda" and torch.cuda.is_available():
                import torch
                self.pipeline.to(torch.device("cuda"))
            
            logger.info("Pyannote pipeline loaded successfully")
            
        except Exception as e:
            logger.error(f"Failed to load Pyannote pipeline: {e}")
            raise
    
    def diarize(
        self,
        audio_data: np.ndarray,
        sample_rate: int = 16000,
        num_speakers: Optional[int] = None,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None
    ) -> Dict[str, Any]:
        """
        Perform speaker diarization on audio data
        
        Args:
            audio_data: Audio samples as numpy array
            sample_rate: Sample rate of audio
            num_speakers: Exact number of speakers (if known)
            min_speakers: Minimum number of speakers
            max_speakers: Maximum number of speakers
            
        Returns:
            Dictionary with diarization results
        """
        if self.pipeline is None:
            raise RuntimeError("Diarization pipeline not loaded")
        
        try:
            import torch
            import torchaudio
            
            # Convert numpy array to tensor
            if audio_data.dtype != np.float32:
                audio_data = audio_data.astype(np.float32)
            
            # Ensure mono
            if len(audio_data.shape) > 1:
                audio_data = audio_data.mean(axis=1)
            
            # Create a temporary file (pyannote works better with files)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                temp_path = f.name
            
            try:
                # Save to temp file
                waveform = torch.from_numpy(audio_data).unsqueeze(0)
                torchaudio.save(temp_path, waveform, sample_rate)
                
                # Run diarization
                diarization_params = {}
                if num_speakers is not None:
                    diarization_params["num_speakers"] = num_speakers
                if min_speakers is not None:
                    diarization_params["min_speakers"] = min_speakers
                if max_speakers is not None:
                    diarization_params["max_speakers"] = max_speakers
                
                diarization = self.pipeline(temp_path, **diarization_params)
                
                # Convert results to list of segments
                segments = []
                for turn, _, speaker in diarization.itertracks(yield_label=True):
                    segments.append({
                        "speaker": speaker,
                        "start": turn.start,
                        "end": turn.end
                    })
                
                # Get unique speakers
                speakers = list(set(seg["speaker"] for seg in segments))
                
                return {
                    "success": True,
                    "segments": segments,
                    "speakers": speakers,
                    "num_speakers": len(speakers)
                }
                
            finally:
                # Clean up temp file
                if os.path.exists(temp_path):
                    os.remove(temp_path)
                    
        except Exception as e:
            logger.error(f"Diarization failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "segments": [],
                "speakers": [],
                "num_speakers": 0
            }
    
    def diarize_file(
        self,
        audio_path: str,
        num_speakers: Optional[int] = None,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None
    ) -> Dict[str, Any]:
        """
        Perform speaker diarization on an audio file
        
        Args:
            audio_path: Path to audio file
            num_speakers: Exact number of speakers (if known)
            min_speakers: Minimum number of speakers
            max_speakers: Maximum number of speakers
            
        Returns:
            Dictionary with diarization results
        """
        if self.pipeline is None:
            raise RuntimeError("Diarization pipeline not loaded")
        
        try:
            diarization_params = {}
            if num_speakers is not None:
                diarization_params["num_speakers"] = num_speakers
            if min_speakers is not None:
                diarization_params["min_speakers"] = min_speakers
            if max_speakers is not None:
                diarization_params["max_speakers"] = max_speakers
            
            diarization = self.pipeline(audio_path, **diarization_params)
            
            segments = []
            for turn, _, speaker in diarization.itertracks(yield_label=True):
                segments.append({
                    "speaker": speaker,
                    "start": turn.start,
                    "end": turn.end
                })
            
            speakers = list(set(seg["speaker"] for seg in segments))
            
            return {
                "success": True,
                "segments": segments,
                "speakers": speakers,
                "num_speakers": len(speakers)
            }
            
        except Exception as e:
            logger.error(f"File diarization failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "segments": [],
                "speakers": [],
                "num_speakers": 0
            }
    
    def unload(self):
        """Unload the pipeline to free memory"""
        if self.pipeline is not None:
            del self.pipeline
            self.pipeline = None
            
            import gc
            gc.collect()
            
            try:
                import torch
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except:
                pass
            
            logger.info("Diarization pipeline unloaded")


def merge_transcription_with_diarization(
    transcription: Dict[str, Any],
    diarization: Dict[str, Any]
) -> List[Dict[str, Any]]:
    """
    Merge transcription segments with speaker diarization
    
    Args:
        transcription: Whisper transcription result
        diarization: Pyannote diarization result
        
    Returns:
        List of segments with both text and speaker information
    """
    if not transcription.get("success") or not diarization.get("success"):
        return transcription.get("segments", [])
    
    trans_segments = transcription.get("segments", [])
    diar_segments = diarization.get("segments", [])
    
    if not diar_segments:
        return trans_segments
    
    merged = []
    
    for trans in trans_segments:
        trans_start = trans["start"]
        trans_end = trans["end"]
        trans_mid = (trans_start + trans_end) / 2
        
        # Find the speaker at the midpoint of this transcription segment
        speaker = None
        for diar in diar_segments:
            if diar["start"] <= trans_mid <= diar["end"]:
                speaker = diar["speaker"]
                break
        
        # If no exact match, find the closest speaker segment
        if speaker is None:
            min_distance = float("inf")
            for diar in diar_segments:
                diar_mid = (diar["start"] + diar["end"]) / 2
                distance = abs(trans_mid - diar_mid)
                if distance < min_distance:
                    min_distance = distance
                    speaker = diar["speaker"]
        
        merged.append({
            "text": trans["text"],
            "start": trans_start,
            "end": trans_end,
            "speaker": speaker or "Unknown",
            "confidence": trans.get("confidence", 0)
        })
    
    return merged
