"""
IPC Server - HTTP server for Swift-Python communication
"""

import logging
import base64
import json
import numpy as np
from typing import Optional

from flask import Flask, request, jsonify

logger = logging.getLogger('WhisperEngine.server')

class WhisperServer:
    """HTTP server for WhisperEngine IPC"""
    
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 5678,
        whisper_service = None,
        diarization_service = None
    ):
        """
        Initialize the server
        
        Args:
            host: Server host
            port: Server port
            whisper_service: WhisperService instance
            diarization_service: DiarizationService instance (optional)
        """
        self.host = host
        self.port = port
        self.whisper_service = whisper_service
        self.diarization_service = diarization_service
        
        self.app = Flask(__name__)
        self._setup_routes()
    
    def _setup_routes(self):
        """Setup Flask routes"""
        
        @self.app.route('/health', methods=['GET'])
        def health():
            """Health check endpoint"""
            return jsonify({
                "status": "ok",
                "whisper_loaded": self.whisper_service is not None and self.whisper_service.model is not None,
                "diarization_loaded": self.diarization_service is not None and self.diarization_service.pipeline is not None
            })
        
        @self.app.route('/info', methods=['GET'])
        def info():
            """Get model information"""
            result = {
                "whisper": self.whisper_service.get_model_info() if self.whisper_service else None,
                "diarization_available": self.diarization_service is not None
            }
            return jsonify(result)
        
        @self.app.route('/transcribe', methods=['POST'])
        def transcribe():
            """
            Transcribe audio
            
            Request body:
            {
                "audio_base64": "...",  // Base64 encoded PCM audio (16-bit, mono)
                "sample_rate": 16000,
                "language": "en",       // Optional language hint
                "enable_diarization": true
            }
            """
            try:
                data = request.get_json()
                
                if not data:
                    return jsonify({"success": False, "error": "No data provided"}), 400
                
                # Decode audio
                audio_base64 = data.get("audio_base64")
                if not audio_base64:
                    return jsonify({"success": False, "error": "No audio data provided"}), 400
                
                audio_bytes = base64.b64decode(audio_base64)
                
                # Convert to numpy array (assuming 16-bit PCM)
                audio_data = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
                
                sample_rate = data.get("sample_rate", 16000)
                language = data.get("language")
                enable_diarization = data.get("enable_diarization", False)
                
                # Transcribe
                if not self.whisper_service:
                    return jsonify({"success": False, "error": "Whisper service not available"}), 503
                
                transcription = self.whisper_service.transcribe(
                    audio_data,
                    sample_rate=sample_rate,
                    language=language
                )
                
                # Optionally add diarization
                if enable_diarization and self.diarization_service:
                    diarization = self.diarization_service.diarize(
                        audio_data,
                        sample_rate=sample_rate
                    )
                    
                    # Merge results
                    if diarization.get("success"):
                        from diarization_service import merge_transcription_with_diarization
                        transcription["segments"] = merge_transcription_with_diarization(
                            transcription, diarization
                        )
                        transcription["speakers"] = diarization.get("speakers", [])
                
                return jsonify(transcription)
                
            except Exception as e:
                logger.error(f"Transcription request failed: {e}")
                return jsonify({"success": False, "error": str(e)}), 500
        
        @self.app.route('/transcribe_file', methods=['POST'])
        def transcribe_file():
            """
            Transcribe an audio file
            
            Request body:
            {
                "file_path": "/path/to/audio.wav",
                "language": "en",
                "enable_diarization": true
            }
            """
            try:
                data = request.get_json()
                
                if not data:
                    return jsonify({"success": False, "error": "No data provided"}), 400
                
                file_path = data.get("file_path")
                if not file_path:
                    return jsonify({"success": False, "error": "No file path provided"}), 400
                
                language = data.get("language")
                enable_diarization = data.get("enable_diarization", False)
                
                # Transcribe
                if not self.whisper_service:
                    return jsonify({"success": False, "error": "Whisper service not available"}), 503
                
                transcription = self.whisper_service.transcribe_file(
                    file_path,
                    language=language
                )
                
                # Optionally add diarization
                if enable_diarization and self.diarization_service:
                    diarization = self.diarization_service.diarize_file(file_path)
                    
                    if diarization.get("success"):
                        from diarization_service import merge_transcription_with_diarization
                        transcription["segments"] = merge_transcription_with_diarization(
                            transcription, diarization
                        )
                        transcription["speakers"] = diarization.get("speakers", [])
                
                return jsonify(transcription)
                
            except Exception as e:
                logger.error(f"File transcription request failed: {e}")
                return jsonify({"success": False, "error": str(e)}), 500
        
        @self.app.route('/diarize', methods=['POST'])
        def diarize():
            """
            Perform speaker diarization only
            
            Request body:
            {
                "audio_base64": "...",
                "sample_rate": 16000,
                "num_speakers": null,
                "min_speakers": null,
                "max_speakers": null
            }
            """
            try:
                if not self.diarization_service:
                    return jsonify({
                        "success": False, 
                        "error": "Diarization service not available"
                    }), 503
                
                data = request.get_json()
                
                if not data:
                    return jsonify({"success": False, "error": "No data provided"}), 400
                
                audio_base64 = data.get("audio_base64")
                if not audio_base64:
                    return jsonify({"success": False, "error": "No audio data provided"}), 400
                
                audio_bytes = base64.b64decode(audio_base64)
                audio_data = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
                
                result = self.diarization_service.diarize(
                    audio_data,
                    sample_rate=data.get("sample_rate", 16000),
                    num_speakers=data.get("num_speakers"),
                    min_speakers=data.get("min_speakers"),
                    max_speakers=data.get("max_speakers")
                )
                
                return jsonify(result)
                
            except Exception as e:
                logger.error(f"Diarization request failed: {e}")
                return jsonify({"success": False, "error": str(e)}), 500
        
        @self.app.route('/unload', methods=['POST'])
        def unload():
            """Unload models to free memory"""
            try:
                if self.whisper_service:
                    self.whisper_service.unload()
                if self.diarization_service:
                    self.diarization_service.unload()
                
                return jsonify({"success": True, "message": "Models unloaded"})
                
            except Exception as e:
                logger.error(f"Unload request failed: {e}")
                return jsonify({"success": False, "error": str(e)}), 500
    
    def run(self, debug: bool = False):
        """Start the server"""
        try:
            from gevent.pywsgi import WSGIServer
            
            logger.info(f"Starting server with gevent at http://{self.host}:{self.port}")
            server = WSGIServer((self.host, self.port), self.app)
            server.serve_forever()
            
        except ImportError:
            logger.warning("gevent not available, falling back to Flask development server")
            self.app.run(
                host=self.host,
                port=self.port,
                debug=debug,
                threaded=True
            )
