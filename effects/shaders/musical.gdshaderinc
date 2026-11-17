// Musical inputs shared by all effect shaders. Set every frame from
// MusicalClock.uniforms(). Phase convention: 0 at beat onset, rising to 1.
// uBarPhase is -1 when bar alignment is unavailable.
uniform float uTime = 0.0;
uniform float uBeatPhase = 0.0;
uniform float uBeatEnvelope = 0.0;
uniform float uBassEnergy = 0.0;
uniform float uOnsetEnvelope = 0.0;
uniform float uBarPhase = -1.0;
