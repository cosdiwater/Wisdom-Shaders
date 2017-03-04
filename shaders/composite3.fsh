/*
 * Copyright 2017 Cheng Cao
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// =============================================================================
//  PLEASE FOLLOW THE LICENSE AND PLEASE DO NOT REMOVE THE LICENSE HEADER
// =============================================================================
//  ANY USE OF THE SHADER ONLINE OR OFFLINE IS CONSIDERED AS INCLUDING THE CODE
//  IF YOU DOWNLOAD THE SHADER, IT MEANS YOU AGREE AND OBSERVE THIS LICENSE
// =============================================================================

#version 120
#extension GL_ARB_shader_texture_lod : require
#pragma optimize(on)

const bool compositeMipmapEnabled = true;

uniform sampler2D depthtex0;
uniform sampler2D gcolor;
uniform sampler2D gdepth;
uniform sampler2D gnormal;
uniform sampler2D composite;
uniform sampler2D gaux1;
uniform sampler2D gaux2;
uniform sampler2D gaux3;
uniform sampler2D noisetex;
uniform sampler2D shadowtex0;

uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;

uniform vec3 shadowLightPosition;
vec3 lightPosition = normalize(shadowLightPosition);
uniform vec3 cameraPosition;
uniform vec3 skyColor;

uniform float viewWidth;
uniform float viewHeight;
uniform float far;
uniform float near;
uniform float frameTimeCounter;
uniform vec3 upVec;
uniform float wetness;
uniform float rainStrength;

uniform bool isEyeInWater;

invariant varying vec2 texcoord;
invariant varying vec3 suncolor;

invariant varying float TimeSunrise;
invariant varying float TimeNoon;
invariant varying float TimeSunset;
invariant varying float TimeMidnight;
invariant varying float extShadow;

invariant varying vec3 skycolor;
invariant varying vec3 fogcolor;
invariant varying vec3 horizontColor;

invariant varying vec3 worldLightPos;
varying vec3 worldSunPosition;

vec3 normalDecode(in vec2 enc) {
	vec4 nn = vec4(2.0 * enc - 1.0, 1.0, -1.0);
	float l = dot(nn.xyz,-nn.xyw);
	nn.z = l;
	nn.xy *= sqrt(l);
	return nn.xyz * 2.0 + vec3(0.0, 0.0, -1.0);
}

const float PI = 3.14159;
const float hPI = PI / 2;

float dFar = 1.0 / far;

struct Mask {
	float flag;

	bool is_valid;
	bool is_water;
	bool is_trans;
	bool is_glass;
};

struct Material {
	vec4 vpos;
	 vec3 normal;
	vec3 wpos;
	 vec3 wnormal;
	float cdepth;
	float cdepthN;
};

struct Global {
	vec4 normaltex;
	vec4 mcdata;
} g;

Material frag;
Mask frag_mask;

vec3 color = texture2D(composite, texcoord).rgb;

void init_struct() {
	frag.vpos = vec4(texture2D(gdepth, texcoord).xyz, 1.0);
	frag.wpos = (gbufferModelViewInverse * frag.vpos).xyz;
	frag.normal = normalDecode(g.normaltex.xy);
	frag.wnormal = mat3(gbufferModelViewInverse) * frag.normal;
	frag.cdepth = length(frag.wpos);
	frag.cdepthN = frag.cdepth * dFar;
	frag_mask.flag = g.mcdata.a;
	frag_mask.is_valid = (frag_mask.flag > 0.01 && frag_mask.flag < 0.97);
	frag_mask.is_water = (frag_mask.flag > 0.71f && frag_mask.flag < 0.79f);
	frag_mask.is_glass = (frag_mask.flag > 0.93);
	frag_mask.is_trans = frag_mask.is_water || frag_mask.is_glass;
}

#define SHADOW_MAP_BIAS 0.9
float fast_shadow_map(in vec3 wpos) {
	if (frag.cdepthN > 0.9f)
		return 0.0f;
	float shade = 0.0;
	vec4 shadowposition = shadowModelView * vec4(wpos, 1.0f);
	shadowposition = shadowProjection * shadowposition;
	float distb = sqrt(shadowposition.x * shadowposition.x + shadowposition.y * shadowposition.y);
	float distortFactor = (1.0f - SHADOW_MAP_BIAS) + distb * SHADOW_MAP_BIAS;
	shadowposition.xy /= distortFactor;
	shadowposition /= shadowposition.w;
	shadowposition = shadowposition * 0.5f + 0.5f;
	float shadowDepth = texture2D(shadowtex0, shadowposition.st).r;
	shade = float(shadowDepth + 0.0005f + frag.cdepthN * 0.05 < shadowposition.z);
	float edgeX = abs(shadowposition.x) - 0.9f;
	float edgeY = abs(shadowposition.y) - 0.9f;
	shade -= max(0.0f, edgeX * 10.0f);
	shade -= max(0.0f, edgeY * 10.0f);
	shade -= clamp((frag.cdepthN - 0.7f) * 5.0f, 0.0f, 1.0f);
	shade = clamp(shade, 0.0f, 1.0f);
	return max(shade, extShadow);
}

const vec3 SEA_WATER_COLOR = vec3(0.69,0.87,0.96);

#define IQ_NOISE

float hash( vec2 p ) {
	float h = dot(p,vec2(127.1,311.7));
	return fract(sin(h)*43758.5453123);
}

float noise( in vec2 p ) {
	vec2 i = floor( p );
	vec2 f = fract( p );
	vec2 u = f*f*(3.0-2.0*f);
	return -1.0+2.0*mix( mix( hash( i + vec2(0.0,0.0) ),
	hash( i + vec2(1.0,0.0) ), u.x),
	mix( hash( i + vec2(0.0,1.0) ),
	hash( i + vec2(1.0,1.0) ), u.x), u.y);
}

// sea
#define SEA_HEIGHT 0.43 // [0.21 0.33 0.43 0.66]
const int ITER_GEOMETRY = 2;
const int ITER_GEOMETRY2 = 5;
const float SEA_CHOPPY = 4.0;
const float SEA_SPEED = 0.8;
const float SEA_FREQ = 0.16;
mat2 octave_m = mat2(1.6,1.1,-1.2,1.6);


float sea_octave(vec2 uv, float choppy) {
	uv += noise(uv);
	vec2 wv = 1.0-abs(sin(uv));
	vec2 swv = abs(cos(uv));
	wv = mix(wv,swv,wv);
	return pow(1.0-pow(wv.x * wv.y,0.75),choppy);
}

float getwave(vec3 p) {
	float freq = SEA_FREQ;
	float amp = SEA_HEIGHT;
	float choppy = SEA_CHOPPY;
	vec2 uv = p.xz ; uv.x *= 0.75;

	float wave_speed = frameTimeCounter * SEA_SPEED;

	float d, h = 0.0;
	for(int i = 0; i < ITER_GEOMETRY; i++) {
		d = sea_octave((uv+wave_speed)*freq,choppy);
		d += sea_octave((uv-wave_speed)*freq,choppy);
		h += d * amp;
		uv *= octave_m; freq *= 1.9; amp *= 0.22; wave_speed *= 1.3;
		choppy = mix(choppy,1.0,0.2);
	}

	float lod = 1.0 - length(p - cameraPosition) / 512.0;

	return (h - SEA_HEIGHT) * lod;
}

float getwave2(vec3 p) {
	float freq = SEA_FREQ;
	float amp = SEA_HEIGHT;
	float choppy = SEA_CHOPPY;
	vec2 uv = p.xz ; uv.x *= 0.75;

	float wave_speed = frameTimeCounter * SEA_SPEED;

	float d, h = 0.0;
	for(int i = 0; i < ITER_GEOMETRY2; i++) {
		d = sea_octave((uv+wave_speed)*freq,choppy);
		d += sea_octave((uv-wave_speed)*freq,choppy);
		h += d * amp;
		uv *= octave_m; freq *= 1.9; amp *= 0.22; wave_speed *= 1.3;
		choppy = mix(choppy,1.0,0.2);
	}

	float lod = 1.0 - length(p - cameraPosition) / 512.0;

	return (h - SEA_HEIGHT) * lod;
}


#define luma(color) dot(color,vec3(0.2126, 0.7152, 0.0722))

vec3 get_water_normal(in vec3 wwpos, in vec3 displacement) {
	vec3 w1 = vec3(0.035, getwave2(wwpos + vec3(0.035, 0.0, 0.0)), 0.0);
	vec3 w2 = vec3(0.0, getwave2(wwpos + vec3(0.0, 0.0, 0.035)), 0.035);
	#define w0 displacement
	#define tangent w1 - w0
	#define bitangent w2 - w0
	return normalize(cross(bitangent, tangent));
}

float DistributionGGX(vec3 N, vec3 H, float roughness) {
	float a      = roughness*roughness;
	float a2     = a*a;
	float NdotH  = max(dot(N, H), 0.0);

	float denom = (NdotH * NdotH * (a2 - 1.0) + 1.0);
	denom = PI * denom * denom;

	return a2 / denom;
}

#define fresnelSchlickRoughness(cosTheta, F0, roughness) (F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0))

#define GeometrySchlickGGX(NdotV, k) (NdotV / (NdotV * (1.0 - k) + k))

float GeometrySmith(vec3 N, vec3 V, vec3 L, float k) {
	float NdotV = max(dot(N, V), 0.0);
	float NdotL = max(dot(N, L), 0.0);
	float ggx1 = GeometrySchlickGGX(NdotV, k);
	float ggx2 = GeometrySchlickGGX(NdotL, k);

	return ggx1 * ggx2;
}

float cloudNoise(in vec3 wpos) {
	vec3 spos = wpos;
	float total;
	vec2 ns = spos.xz + cameraPosition.xz + frameTimeCounter * vec2(18.0, 2.0);
	ns.y *= 0.73;
	ns *= 0.0008;

	vec2 coord = ns;

	// Shape
	float n  = noise(coord) * 0.5;   coord *= 3.0;
  n += noise(coord) * 0.25;  coord *= 3.01;
  n += noise(coord) * 0.125; coord *= 3.02;
  n += noise(coord) * 0.0625;

	total = n;

	ns *= 2.0;
	ns -= frameTimeCounter * 0.3;
	float f = 0.50000 * noise(ns); ns = ns * 0.7;
	f += 0.25000 * noise(ns); ns = ns * 0.9;
	f += 0.12500 * noise(ns);
	total += f * total;

	float weight = 0.4;
	f = 0.0; ns *= 3.0;
	for (int i=0; i<5; i++){
		f += (weight * noise(ns + frameTimeCounter * 0.1));
		ns = 1.2 * ns;
		weight *= 0.6;
	}
	total += max(0.0, f) * total * 0.5;

	total = clamp(0.0, total, 1.0);

	return total;
}

vec4 calcCloud(in vec3 wpos, in vec3 mie, in vec3 L) {
	if (wpos.y < 0.03) return vec4(0.0);

	vec3 spos = wpos / wpos.y * 2850.0;
	float total = cloudNoise(spos);

	float density = cloudNoise(spos + worldLightPos * 3.0);

	vec3 cloud_color = L * 0.7 * (1.0 - density) + mie * 1.4 * (1.0 - total) * (1.0 - density) + skyColor * (1.0 - total * 0.5);
	cloud_color *= 1.0 - rainStrength * 0.8;
	total *= 1.0 - min(1.0, (length(wpos.xz) - 0.9) * 10.0);

	total = clamp(0.0, total, 1.0);

	return vec4(cloud_color, total);
}


vec3 mie(float dist, vec3 sunL){
	return max(exp(-pow(dist, 0.25)) * sunL - 0.4, 0.0);
}

vec3 calcSkyColor(vec3 wpos, float camHeight){
	const float coeiff = 0.5785;
	float rain = (1.0 - rainStrength * 0.9);
	vec3 totalSkyLight = vec3(0.151, 0.311, 1.0) * 0.3 * rain;

	float sunDistance = distance(normalize(wpos), worldSunPosition);
	float moonDistance = distance(normalize(wpos), -worldSunPosition);
	sunDistance *= 0.5; moonDistance *= 0.5;

	float sunH = worldSunPosition.y * 1.589;

	float sunScatterMult = clamp(sunDistance, 0.0, 1.0);
	float sun = clamp(1.0 - smoothstep(0.01, 0.018, sunScatterMult), 0.0, 1.0) * rain;

	float moonScatterMult = clamp(moonDistance, 0.0, 1.0);
	float moon = clamp(1.0 - smoothstep(0.01, 0.011, moonScatterMult), 0.0, 1.0) * rain;

	float horizont = max(0.001, normalize(wpos + vec3(0.0, camHeight, 0.0)).y);
	horizont = (coeiff * mix(sunScatterMult, 1.0, horizont)) / horizont;

	vec3 sunMieScatter = mie(sunDistance, vec3(1.0, 1.0, 0.984) * rain);
	vec3 moonMieScatter = mie(moonDistance, vec3(1.0, 1.0, 0.984) * 0.1 * rain);

	vec3 sky = horizont * totalSkyLight;
	sky = max(sky, 0.0);

	sky = max(mix(pow(sky, 1.0 - sky), sky / (2.0 * sky + 0.5 - sky), clamp(sunH * 2.0, 0.0, 1.0)),0.0);

	float underscatter = distance(sunH * 0.5 + 0.5, 1.0);
	sky = mix(sky, vec3(0.0), clamp(underscatter, 0.0, 1.0)) + sunMieScatter + moonMieScatter;

	vec4 cloud = calcCloud(normalize(wpos), sunMieScatter, sky);

	sky += sun + moon;
	sky *= 1.0 + pow(1.0 - sunScatterMult, 10.0) * 10.0;
	sky *= 1.0 + pow(1.0 - moonScatterMult, 20.0) * 5.0;

	sky = mix(sky, cloud.rgb, cloud.a);

	return sky;
}

#define rand(co) fract(sin(dot(co.xy,vec2(12.9898,78.233))) * 43758.5453)
#define PLANE_REFLECTION
#ifdef PLANE_REFLECTION

#define BISEARCH(SEARCHPOINT, DIRVEC, SIGN) DIRVEC *= 0.5; SEARCHPOINT+= DIRVEC * SIGN; uv = getScreenCoordByViewCoord(SEARCHPOINT); sampleDepth = linearizeDepth(texture2DLod(depthtex0, uv, 0.0).x); testDepth = getLinearDepthOfViewCoord(SEARCHPOINT); SIGN = sign(sampleDepth - testDepth);

float linearizeDepth(float depth) { return (2.0 * near) / (far + near - depth * (far - near));}

vec2 getScreenCoordByViewCoord(vec3 viewCoord) {
	vec4 p = vec4(viewCoord, 1.0);
	p = gbufferProjection * p;
	p /= p.w;
	if(p.z < -1 || p.z > 1)
		return vec2(-1.0);
	p = p * 0.5f + 0.5f;
	return p.st;
}

float getLinearDepthOfViewCoord(vec3 viewCoord) {
	vec4 p = vec4(viewCoord, 1.0);
	p = gbufferProjection * p;
	p /= p.w;
	return linearizeDepth(p.z * 0.5 + 0.5);
}

vec4 waterRayTarcing(vec3 startPoint, vec3 direction, vec3 color, float metal) {
	const float stepBase = 0.025;
	vec3 testPoint = startPoint;
	direction *= stepBase;
	bool hit = false;
	vec4 hitColor = vec4(0.0);
	vec3 lastPoint = testPoint;
	for(int i = 0; i < 40; i++) {
		testPoint += direction * pow(float(i + 1), 1.46);
		vec2 uv = getScreenCoordByViewCoord(testPoint + direction * rand(vec2((texcoord.x + texcoord.y) * 0.5, i * 0.01)));
		if(uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
			hit = true;
			break;
		}
		float sampleDepth = texture2DLod(depthtex0, uv, 0.0).x;
		sampleDepth = linearizeDepth(sampleDepth);
		float testDepth = getLinearDepthOfViewCoord(testPoint);
		if(sampleDepth < testDepth && testDepth - sampleDepth < (1.0 / 2048.0) * (1.0 + testDepth * 200.0 + float(i))){
			vec3 finalPoint = lastPoint;
			float _sign = 1.0;
			direction = testPoint - lastPoint;
			BISEARCH(finalPoint, direction, _sign);
			BISEARCH(finalPoint, direction, _sign);
			BISEARCH(finalPoint, direction, _sign);
			BISEARCH(finalPoint, direction, _sign);
			uv = getScreenCoordByViewCoord(finalPoint);
			hitColor = vec4(texture2DLod(composite, uv, 3.0 - metal * 3.0).rgb, 0.0);
			hitColor.a = clamp(1.0 - pow(distance(uv, vec2(0.5))*2.0, 4.0), 0.0, 1.0);
			float newflag = texture2D(gaux2, uv).a;
			hitColor.a *= 1.0 - float(newflag > 0.71f && newflag < 0.79f);
			hit = true;
			break;
		}
		lastPoint = testPoint;
	}
	return hitColor;
}
#endif

#define Brightness 4.0 // [1.0 2.0 4.0 6.0]

#define ENHANCED_WATER
#define WATER_PARALLAX
#ifdef WATER_PARALLAX
void WaterParallax(inout vec3 wpos) {
	const int maxLayers = 6;

	vec3 nwpos = normalize(wpos);
	vec3 fpos = nwpos / max(0.1, abs(nwpos.y)) * SEA_HEIGHT;
	float exph = 0.0;
	float hstep = 1.0 / float(maxLayers);

	float h;
	for (int i = 0; i < maxLayers; i++) {
		h = getwave(wpos + cameraPosition);
		hstep *= 1.3;

		if (h + 0.05 > exph) break;

		exph -= hstep;
		wpos += vec3(fpos.x, 0.0, fpos.z) * hstep;
	}
	wpos -= vec3(fpos.x, 0.0, fpos.z) * abs(h - exph) * hstep;
}
#endif
// #define BLACK_AND_WHITE
#define SKY_REFLECTIONS

/* DRAWBUFFERS:3 */
void main() {
	g.normaltex = texture2D(gnormal, texcoord);
	g.mcdata = texture2D(gaux2, texcoord);
	init_struct();
	float shade = g.mcdata.b;

	float is_shaded = pow(g.mcdata.g, 10);
	float wetness2 = is_shaded * wetness;
	// * (max(dot(normal, vec3(0.0, 1.0, 0.0)), 0.0) * 0.5 + 0.5);
	vec3 ambientColor = vec3(0.155, 0.16, 0.165) * (luma(suncolor) * 0.3);

	vec4 org_specular = texture2D(gaux1, texcoord);
	if (frag_mask.is_glass || frag_mask.flag > 0.97) {
		vec4 shifted_vpos = vec4(frag.vpos.xyz + normalize(refract(normalize(frag.vpos.xyz), normalDecode(g.normaltex.zw), 1.0f / 1.4f)), 1.0);
		shifted_vpos = gbufferProjection * shifted_vpos;
		shifted_vpos /= shifted_vpos.w;
		shifted_vpos = shifted_vpos * 0.5f + 0.5f;
		vec2 shifted = shifted_vpos.st;

		color = texture2D(composite, shifted).rgb;
		color += texture2DLod(composite, shifted, 1.0).rgb * 0.6;
		color += texture2DLod(composite, shifted, 2.0).rgb * 0.4;
		color *= 0.5;

		color = color * org_specular.rgb;//, org_specular.rgb, pow(org_specular.a, 3.0));

		if (frag_mask.is_valid) org_specular = vec4(0.1, 0.96, 0.0, 1.0);
	}

	if (frag_mask.is_valid) {
		vec4 water_vpos = vec4(texture2D(gaux3, texcoord).xyz, 1.0);
		vec4 ovpos = water_vpos;
		vec3 water_wpos = (gbufferModelViewInverse * water_vpos).xyz;
		vec3 water_plain_normal;
		vec3 owpos = water_wpos;
		vec3 water_displacement;
		if (frag_mask.is_glass) {
			frag.vpos = water_vpos;
			frag.wpos = water_wpos;
			frag.normal = normalDecode(g.normaltex.zw);
		}
		if (isEyeInWater || frag_mask.is_water) {
			vec3 vvnormal_plain = normalDecode(g.normaltex.zw);
			water_plain_normal = mat3(gbufferModelViewInverse) * vvnormal_plain;

			#ifdef WATER_PARALLAX
			WaterParallax(water_wpos);
			float wave = getwave2(water_wpos + cameraPosition);
			#else
			float wave = getwave2(water_wpos + cameraPosition);
			vec2 p = water_vpos.xy / water_vpos.z * wave;
			wave = getwave2(water_wpos + cameraPosition - vec3(p.x, 0.0, p.y));
			vec2 wp = length(p) * normalize(water_wpos).xz;
			water_wpos -= vec3(wp.x, 0.0, wp.y);
			#endif

			water_displacement = wave * water_plain_normal;
			vec3 water_normal = (water_plain_normal.y > 0.8) ? get_water_normal(water_wpos + cameraPosition, water_displacement) : water_plain_normal;

			vec3 vsnormal = normalize(mat3(gbufferModelView) * water_normal);
			water_vpos = (!frag_mask.is_water && isEyeInWater) ? frag.vpos : gbufferModelView * vec4(water_wpos, 1.0);
			#ifdef ENHANCED_WATER
			const float refindex = 0.7;
			vec4 shifted_vpos = vec4(frag.vpos.xyz + normalize(refract(normalize(frag.vpos.xyz), vsnormal, refindex)), 1.0);
			shifted_vpos = gbufferProjection * shifted_vpos;
			shifted_vpos /= shifted_vpos.w;
			shifted_vpos = shifted_vpos * 0.5f + 0.5f;
			vec2 shifted = shifted_vpos.st;
			#else
			vec2 shifted = texcoord + water_normal.xz;
			#endif

			float shifted_flag = texture2D(gaux2, shifted).a;

			if (shifted_flag < 0.71f || shifted_flag > 0.92f) {
				shifted = texcoord;
			}
			frag.vpos = vec4(texture2D(gdepth, shifted).xyz, 1.0);
			float dist_diff = isEyeInWater ? length(water_vpos.xyz) : distance(frag.vpos.xyz, water_vpos.xyz);
			float dist_diff_N = pow(clamp(0.0, abs(dist_diff) / 6.0, 1.0), 0.2);

			vec3 org_color = color;
			color = texture2DLod(composite, shifted, 0.0).rgb;
			color = mix(color, texture2DLod(composite, shifted, 1.0).rgb, dist_diff_N * 0.8);
			color = mix(color, texture2DLod(composite, shifted, 2.0).rgb, dist_diff_N * 0.6);
			color = mix(color, texture2DLod(composite, shifted, 3.0).rgb, dist_diff_N * 0.4);

			color = mix(color, org_color, pow(length(shifted - vec2(0.5)) / 1.414f, 2.0));
			if (shifted.x > 1.0 || shifted.x < 0.0 || shifted.y > 1.0 || shifted.y < 0.0) {
				color *= 0.5 + pow(length(shifted - vec2(0.5)) / 1.414f, 2.0);
			}

			vec3 watercolor = skycolor * 0.15 * vec3(0.17, 0.41, 0.68) * luma(suncolor);
			color = SEA_WATER_COLOR * mix(color, watercolor, dist_diff_N);

			shade = fast_shadow_map(water_wpos);

			frag.wpos = water_wpos;
			frag.normal = vsnormal;
			frag.vpos.xyz = water_vpos.xyz;
			frag.wnormal = water_normal;
		}

		frag.wpos.y -= 1.67f;
		// Preprocess Specular
		vec3 specular = vec3(0.0);
		specular.r = min(org_specular.g, 0.9999);
		specular.g = org_specular.r;
		specular.b = org_specular.b;

		if (!frag_mask.is_water) {
			vec3 cwpos = frag.wpos + cameraPosition;
			float wetness_distribution = texture2D(noisetex, cwpos.xz * 0.01).r + texture2D(noisetex, cwpos.yz  * 0.01).r;
			wetness_distribution = wetness_distribution * 0.5 + 0.8 * (texture2D(noisetex, cwpos.zx * 0.002).r + texture2D(noisetex, cwpos.yx  * 0.002).r);
			wetness_distribution *= wetness_distribution * wetness2;
			wetness_distribution *= wetness_distribution;
			wetness_distribution = clamp(wetness_distribution, 0.0, 1.0);
			if (specular.g < 0.000001f) specular.g = 0.4;
			specular.g = clamp(0.003, specular.g - wetness2 * 0.005, 0.9999);
			specular.g = mix(specular.g, 0.1, wetness_distribution);

			specular.r = clamp(0.00001, specular.r + wetness2 * 0.25, 0.7);
			specular.r = mix(specular.r, 0.3, wetness_distribution);
		}

		if (!isEyeInWater){
			// Specular definition:
			//  specular.g -> Roughness
			//  specular.r -> Metalness (Reflectness)
			//  specular.b (PBR only) -> Light emmission (Self lighting)
			vec3 halfwayDir = normalize(lightPosition - normalize(frag.vpos.xyz));
			//spec = clamp(0.0, spec, 1.0 - wetness2 * 0.5);

			vec3 ref_color = vec3(0.0);
			vec3 viewRefRay = vec3(0.0);
			if (!isEyeInWater && specular.r > 0.01) {
				vec3 vs_plain_normal = mat3(gbufferModelView) * water_plain_normal;
				viewRefRay = reflect(normalize(frag.vpos.xyz), normalize(frag.normal + vec3(rand(texcoord), 0.0, rand(texcoord.yx)) * specular.g * specular.g * 0.05));
				#ifdef PLANE_REFLECTION
				vec3 refnormal = frag_mask.is_water ? normalize(mix(frag.normal, vs_plain_normal, 0.9)) : frag.normal;
				vec3 plainRefRay = reflect(normalize(frag.vpos.xyz), normalize(refnormal + vec3(rand(texcoord), 0.0, rand(texcoord.yx)) * specular.g * specular.g * 0.05));

				vec4 reflection = waterRayTarcing(frag.vpos.xyz + refnormal * max(0.4, length(frag.vpos.xyz) / far), plainRefRay, color, specular.r);
				ref_color = reflection.rgb * reflection.a * specular.r;
				#else
				vec4 reflection = vec4(0.0);
				#endif

				#ifdef SKY_REFLECTIONS
				vec3 wref = reflect(normalize(frag.wpos), frag.wnormal) * 480.0;
				if (frag_mask.is_water) wref.y = abs(wref.y);
				ref_color += calcSkyColor(wref, cameraPosition.y + frag.wpos.y) * (1.0 - reflection.a) * specular.r;
				#else
				ref_color += skycolor * (1.0 - reflection.a) * specular.r;
				#endif
			}

			if (specular.r > 0.07) {
				specular.g = clamp(0.0001, specular.g, 0.9999);
				specular.r = clamp(0.0001, specular.r, 0.9999);
				vec3 V = -normalize(frag.vpos.xyz);
				vec3 F0 = vec3(specular.r + 0.08);
				F0 = mix(F0, color, 1.0 - specular.r);
				vec3 F = frag_mask.is_water ? vec3(1.0) : fresnelSchlickRoughness(max(dot(frag.normal, V), 0.0), F0, specular.g);

				if (frag_mask.is_trans) {

					vec3 halfwayDir = normalize(lightPosition - normalize(frag.vpos.xyz));
					float stdNormal = DistributionGGX(frag.normal, halfwayDir, specular.g);

					vec3 no = GeometrySmith(frag.normal, V, lightPosition, specular.g) * stdNormal * F;
					float denominator = max(0.0, 4 * max(dot(V, frag.normal), 0.0) * max(dot(lightPosition, frag.normal), 0.0) + 0.001);
					vec3 brdf = no / denominator;

					color += brdf * skycolor * (1.0 - shade);
				}

				float reflection_fresnel_mul = frag_mask.is_trans ? 3.0 : 1.5;
				float fresnel = pow(1.0 - dot(viewRefRay, frag.normal), reflection_fresnel_mul);
				ref_color = mix(fogcolor, ref_color, clamp((512.0 - frag.cdepth) / (512.0 - 32.0), 0.0, 1.0));
				color += ref_color * F * fresnel;
			}

			frag.cdepth = length(max(frag.wpos, water_wpos));
		}
	} else {
		vec4 viewPosition = gbufferProjectionInverse * vec4(texcoord.s * 2.0 - 1.0, texcoord.t * 2.0 - 1.0, 1.0, 1.0f);
		viewPosition /= viewPosition.w;
		vec4 worldPosition = normalize(gbufferModelViewInverse * viewPosition) * 480.0 * 2.0;

		frag.wpos = worldPosition.xyz;

		vec3 skycolor = calcSkyColor(frag.wpos, cameraPosition.y);
		color = frag_mask.flag > 0.97 ? skycolor * org_specular.rgb : skycolor;
	}

	#ifdef BLACK_AND_WHITE
	color = vec3(luma(color));
	#endif

	gl_FragData[0] = vec4(clamp(vec3(0.0), color, vec3(6.0)), 1.0);
}
