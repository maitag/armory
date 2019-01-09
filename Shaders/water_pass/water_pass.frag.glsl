// Deferred water based on shader by Wojciech Toman
// http://www.gamedev.net/page/resources/_/technical/graphics-programming-and-theory/rendering-water-as-a-post-process-effect-r2642
// Seascape https://www.shadertoy.com/view/Ms2SD1 
// Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License
#version 450

#include "compiled.inc"
#include "std/gbuffer.glsl"

uniform sampler2D gbufferD;

uniform float time;
uniform vec3 eye;
uniform vec3 eyeLook;
uniform vec2 cameraProj;
uniform vec3 ld;
uniform float envmapStrength;

in vec2 texCoord;
in vec3 viewRay;
in vec3 vecnormal;
out vec4 fragColor;

float hash(vec2 p) {
	float h = dot(p, vec2(127.1, 311.7));	
	return fract(sin(h) * 43758.5453123);
}
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return -1.0 + 2.0 * mix(
				mix(hash(i + vec2(0.0, 0.0)), 
					hash(i + vec2(1.0, 0.0)), u.x),
				mix(hash(i + vec2(0.0, 1.0)), 
					hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float seaOctave(vec2 uv, float choppy) {
	uv += noise(uv);        
	vec2 wv = 1.0 - abs(sin(uv));
	vec2 swv = abs(cos(uv));    
	wv = mix(wv, swv, wv);
	return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}
const mat2 octavem = mat2(1.6, 1.2, -1.2, 1.6);
float map(vec3 p) {
	float freq = seaFreq;
	float amp = seaHeight;
	float choppy = seaChoppy;
	vec2 uv = p.xy;
	uv.x *= 0.75;
	
	float d, h = 0.0;
	for(int i = 0; i < 2; i++) {
		d = seaOctave((uv + (time * seaSpeed)) * freq, choppy);
		d += seaOctave((uv - (time * seaSpeed)) * freq, choppy);
		h += d * amp;
		uv *= octavem; freq *= 1.9; amp *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
	}
	return p.z - h;
}
float mapDetailed(vec3 p) {
	float freq = seaFreq;
	float amp = seaHeight;
	float choppy = seaChoppy;
	vec2 uv = p.xy; uv.x *= 0.75;
	
	float d, h = 0.0;    
	for(int i = 0; i < 4; i++) {       
		d = seaOctave((uv + (time * seaSpeed)) * freq,choppy);
		d += seaOctave((uv - (time * seaSpeed)) * freq,choppy);
		h += d * amp;        
		uv *= octavem; freq *= 1.9; amp *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
	}
	return p.z - h;
}
vec3 getNormal(vec3 p, float eps) {
	vec3 n;
	n.z = mapDetailed(p);    
	n.x = mapDetailed(vec3(p.x + eps, p.y, p.z)) - n.z;
	n.y = mapDetailed(vec3(p.x, p.y + eps, p.z)) - n.z;
	n.z = eps;
	return normalize(n);
}
vec3 heightMapTracing(vec3 ori, vec3 dir) {
	vec3 p;
	float tm = 0.0;
	float tx = 1000.0;    
	float hx = mapDetailed(ori + dir * tx);
	if(hx > 0.0) return p;   
	float hm = mapDetailed(ori + dir * tm);    
	float tmid = 0.0;
	for(int i = 0; i < 5; i++) {
		tmid = mix(tm, tx, hm / (hm - hx));                
		p = ori + dir * tmid;
		float hmid = mapDetailed(p);
		if (hmid < 0.0) {
			tx = tmid;
			hx = hmid;
		}
		else {
			tm = tmid;
			hm = hmid;
		}
	}
	return p;
}
vec3 getSkyColor(vec3 e) {
	e.z = max(e.z, 0.0);
	vec3 ret;
	ret.x = pow(1.0 - e.z, 2.0);
	ret.z = 1.0 - e.z;
	ret.y = 0.6 + (1.0 - e.z) * 0.4;
	return ret;
}
float diffuse(vec3 n, vec3 l, float p) {
	return pow(dot(n, l) * 0.4 + 0.6, p);
}
float specular(vec3 n, vec3 l, vec3 e, float s) {    
	float nrm = (s + 8.0) / (3.1415 * 8.0);
	return pow(max(dot(reflect(e, n), l), 0.0), s) * nrm;
}
vec3 getSeaColor(vec3 p, vec3 n, vec3 l, vec3 eye, vec3 dist) {  
	float fresnel = 1.0 - max(dot(n, -eye), 0.0);
	fresnel = pow(fresnel, 3.0) * 0.65;
	vec3 reflected = getSkyColor(reflect(eye, n));   
	vec3 refracted = seaBaseColor + diffuse(n, l, 80.0) * seaWaterColor * 0.12; 
	vec3 color = mix(refracted, reflected, fresnel);
	float atten = max(1.0 - dot(dist, dist) * 0.001, 0.0);
	color += seaWaterColor * (p.z - seaHeight) * 0.18 * atten;
	color += vec3(specular(n, l, eye, 60.0));
	return color;
}

void main() {
	float gdepth = textureLod(gbufferD, texCoord, 0.0).r * 2.0 - 1.0;
	if (gdepth == 1.0) {
		fragColor = vec4(0.0);
		return;
	}
	
	vec3 color = vec3(1.0);
	vec3 vray = normalize(viewRay);
	vec3 position = getPos(eye, eyeLook, vray, gdepth, cameraProj);
	
	if (eye.z < seaLevel) {
		fragColor = vec4(0.0);
		return;
	}

	if (position.z > seaLevel + seaMaxAmplitude) {
		fragColor = vec4(0.0);
		return;
	}

	vec3 eyeDir = eye - position.xyz;
	vec3 v = normalize(eyeDir);
	
	vec3 surfacePoint = heightMapTracing(eye, -v);
	float depthZ = surfacePoint.z - position.z;
	
	float dist = max(0.1, length(surfacePoint - eye) * 1.2);
	float epsx = dot(dist, dist) * 0.00005; // Fade in distance to prevent noise
	vec3 normal = getNormal(surfacePoint, epsx);
	
	color = getSeaColor(surfacePoint, normal, ld, -v, surfacePoint - eye) * max(0.5, (envmapStrength + 0.2) * 1.4);
	
	// Fade on horizon
	vec3 vecn = normalize(vecnormal);
	color = mix(color, vec3(1.0), clamp((vecn.z + 0.03) * 10.0, 0.0, 1.0));

	fragColor.rgb = color;
	fragColor.a = clamp(depthZ * seaFade, 0.0, 1.0);
}
