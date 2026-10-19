"""Two synthetic clients send audio/video through AWS, then delete the test room.

Requires livekit + livekit-api in a temporary venv and an SSH tunnel on 17880.
Reads ignored deploy/.secrets/server.env; never prints credentials or tokens.
Use --relay to require TURN instead of direct ICE.
"""
import asyncio
import math
import sys
import uuid
from array import array
from datetime import timedelta
from pathlib import Path

from livekit import api, rtc


async def main():
    env = dict(line.split('=', 1) for line in
               (Path(__file__).parent / '.secrets/server.env').read_text().splitlines()
               if line and not line.startswith('#'))
    key, secret = env['LIVEKIT_API_KEY'], env['LIVEKIT_API_SECRET']
    service = api.LiveKitAPI('http://127.0.0.1:17880', key, secret)
    name = 'deployment-check-' + uuid.uuid4().hex
    rooms = [rtc.Room(), rtc.Room()]
    tasks = []
    counts = [{'audio': 0, 'video': 0} for _ in rooms]

    async def receive(track, index):
        is_audio = track.kind == rtc.TrackKind.KIND_AUDIO
        stream = rtc.AudioStream(track) if is_audio else rtc.VideoStream(track)
        kind = 'audio' if is_audio else 'video'
        try:
            async for event in stream:
                if is_audio:
                    # Require non-silent samples, not just a subscribed track.
                    if max(abs(x) for x in event.frame.data) > 100:
                        counts[index][kind] += 1
                else:
                    if event.frame.width == 160 and event.frame.height == 120:
                        counts[index][kind] += 1
        finally:
            await stream.aclose()

    async def transmit(room):
        audio_source = rtc.AudioSource(48000, 1)
        video_source = rtc.VideoSource(160, 120)
        audio = rtc.LocalAudioTrack.create_audio_track('test-tone', audio_source)
        video = rtc.LocalVideoTrack.create_video_track('test-color', video_source)
        await room.local_participant.publish_track(audio, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        await room.local_participant.publish_track(video, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_CAMERA))
        try:
            for n in range(400):
                samples = array('h', (int(5000 * math.sin(2 * math.pi * 440 * (n * 480 + i) / 48000)) for i in range(480)))
                await audio_source.capture_frame(rtc.AudioFrame(samples.tobytes(), 48000, 1, 480))
                if n % 5 == 0:
                    pixels = bytes([30, 140, 220, 255]) * (160 * 120)
                    video_source.capture_frame(rtc.VideoFrame(160, 120, rtc.VideoBufferType.RGBA, pixels))
                await asyncio.sleep(0.01)
        finally:
            await audio_source.aclose()
            await video_source.aclose()

    try:
        await service.room.create_room(api.CreateRoomRequest(name=name, max_participants=2, empty_timeout=30))
        for index, room in enumerate(rooms):
            def subscribed(track, publication, participant, i=index):
                tasks.append(asyncio.create_task(receive(track, i)))
            room.on('track_subscribed', subscribed)
            token = (api.AccessToken(key, secret).with_identity(f'check-{index}')
                     .with_ttl(timedelta(minutes=2))
                     .with_grants(api.VideoGrants(room_join=True, room=name, room_create=False)).to_jwt())
            options = rtc.RoomOptions(connect_timeout=20)
            if '--relay' in sys.argv:
                options.rtc_config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY)
            await room.connect(env['LIVEKIT_PUBLIC_URL'], token, options=options)
        await asyncio.wait_for(asyncio.gather(*(transmit(room) for room in rooms)), timeout=30)
        await asyncio.sleep(1)
        print({'transport': 'relay' if '--relay' in sys.argv else 'automatic', 'received_frames': counts})
        assert all(c['audio'] >= 10 and c['video'] >= 5 for c in counts), 'Media did not arrive in both directions'
    finally:
        for room in rooms:
            await room.disconnect()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await service.room.delete_room(api.DeleteRoomRequest(room=name))
        await service.aclose()


if __name__ == '__main__':
    asyncio.run(main())
