#!/usr/bin/env python3
"""
WhisperEngine - Main Entry Point
Provides speech-to-text with speaker diarization for LCT macOS
"""

import argparse
import logging
import signal
import sys
from pathlib import Path

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('WhisperEngine')

def signal_handler(sig, frame):
    """Handle shutdown signals gracefully"""
    logger.info("Shutting down WhisperEngine...")
    sys.exit(0)

def main():
    parser = argparse.ArgumentParser(description='WhisperEngine - Speech Recognition Backend')
    parser.add_argument('--port', type=int, default=5678, help='HTTP server port')
    parser.add_argument('--host', type=str, default='127.0.0.1', help='HTTP server host')
    parser.add_argument('--model', type=str, default='base', 
                        choices=['tiny', 'base', 'small', 'medium', 'large'],
                        help='Whisper model size')
    parser.add_argument('--device', type=str, default='auto',
                        choices=['auto', 'cpu', 'cuda', 'mps'],
                        help='Compute device')
    parser.add_argument('--hf-token', type=str, default='',
                        help='Hugging Face token for Pyannote')
    parser.add_argument('--no-diarization', action='store_true',
                        help='Disable speaker diarization')
    
    args = parser.parse_args()
    
    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    logger.info(f"Starting WhisperEngine with model: {args.model}")
    
    # Import services (lazy import to show startup progress)
    try:
        from ipc_server import WhisperServer
        from whisper_service import WhisperService
        from diarization_service import DiarizationService
        
        # Initialize services
        whisper_service = WhisperService(
            model_size=args.model,
            device=args.device
        )
        
        diarization_service = None
        if not args.no_diarization and args.hf_token:
            try:
                diarization_service = DiarizationService(hf_token=args.hf_token)
                logger.info("Speaker diarization enabled")
            except Exception as e:
                logger.warning(f"Failed to initialize diarization: {e}")
                logger.warning("Continuing without speaker diarization")
        elif args.no_diarization:
            logger.info("Speaker diarization disabled by user")
        else:
            logger.warning("No HuggingFace token provided, speaker diarization disabled")
        
        # Start server
        server = WhisperServer(
            host=args.host,
            port=args.port,
            whisper_service=whisper_service,
            diarization_service=diarization_service
        )
        
        logger.info(f"WhisperEngine ready at http://{args.host}:{args.port}")
        server.run()
        
    except ImportError as e:
        logger.error(f"Failed to import required modules: {e}")
        logger.error("Please install dependencies: pip install -r requirements.txt")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Failed to start WhisperEngine: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
