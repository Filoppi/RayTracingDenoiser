/*
Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE(cbuffer, globalConstants, b, 0, 0)
{
    float4x4    gClipToWorld;
    float4x4    gViewToClip;

    int2        gResolution;
    float2      gInvViewSize;

    float       gSpecularPhiLuminance;
    float       gDiffusePhiLuminance;
    float       gPhiDepth;
    float       gPhiNormal;

    uint        gStepSize;
    float       gRoughnessEdgeStoppingRelaxation;
    float       gNormalEdgeStoppingRelaxation;
    float       gLuminanceEdgeStoppingRelaxation;
};

#include "RELAX_Common.hlsl"

// Inputs
NRI_RESOURCE(Texture2D<float4>, gSpecularIlluminationAndVariance, t, 0, 0);
NRI_RESOURCE(Texture2D<float4>, gDiffuseIlluminationAndVariance, t, 1, 0);
NRI_RESOURCE(Texture2D<float>, gHistoryLength, t, 2, 0);
NRI_RESOURCE(Texture2D<float>, gSpecularReprojectionConfidence, t, 3, 0);
NRI_RESOURCE(Texture2D<uint2>, gNormalRoughnessDepth, t, 4, 0);

// Outputs
NRI_RESOURCE(RWTexture2D<float4>, gOutSpecularIlluminationAndVariance, u, 0, 0);
NRI_RESOURCE(RWTexture2D<float4>, gOutDiffuseIlluminationAndVariance, u, 1, 0);

groupshared uint4       sharedPackedIlluminationAndVariance[16 + 1 + 1][16 + 1 + 1];
groupshared float4      sharedNormalRoughness[16 + 1 + 1][16 + 1 + 1];
groupshared float4      sharedWorldPos[16 + 1 + 1][16 + 1 + 1];

// Helper macros
#define linearStep(a, b, x) saturate((x - a)/(b - a))
#define PI 3.141593

#define smoothStep01(x) (x*x*(3.0 - 2.0*x))

float smoothStep(float a, float b, float x)
{
    x = linearStep(a, b, x); return smoothStep01(x);
}

// Helper functions
float3 getCurrentWorldPos(int2 pixelPos, float depth)
{
    float2 uv = ((float2)pixelPos + float2(0.5, 0.5)) * gInvViewSize;
    float4 clipPos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1);
    float4 worldPos = mul(gClipToWorld, clipPos);
    return worldPos.xyz / worldPos.w;
}

float getGeometryWeight(float3 centerWorldPos, float3 centerNormal, float3 sampleWorldPos, float phiDepth)
{
    float distanceToCenterPointPlane = abs(dot(sampleWorldPos - centerWorldPos, centerNormal));
    return (isnan(distanceToCenterPointPlane) ? 1.0 : distanceToCenterPointPlane) / (phiDepth + 1e-6);
}

float getDiffuseNormalWeight(float3 centerNormal, float3 sampleNormal, float phiNormal)
{
    return pow(saturate(dot(centerNormal, sampleNormal)), phiNormal);
}

float getSpecularLobeHalfAngle(float roughness)
{
    // Defines a cone angle, where micro-normals are distributed
    float m = roughness * roughness;

    // Approximation of https://seblagarde.files.wordpress.com/2015/07/course_notes_moving_frostbite_to_pbr_v32.pdf (page 72)
    // for [0..1] domain:

    // float k = 0.75; // % of NDF volume. Is it the trimming factor from VNDF sampling?
    // return atan(m * k / (1.0 - k));

    return PI * m / (1.0 + 0.5*m + m * roughness);
}

float2 getRoughnessWeightParams(float roughness0, float specularReprojectionConfidence)
{
    float a = 1.0 / (0.001 + 0.999 * roughness0 * (0.333 + gRoughnessEdgeStoppingRelaxation * (1.0 - specularReprojectionConfidence)));
    float b = roughness0 * a;
    return float2(a, b);
}

float getRoughnessWeight(float2 params0, float roughness)
{
    return saturate(1.0 - abs(params0.y - roughness * params0.x));
}

float2 getNormalWeightParams(float roughness, float numFramesInHistory, float specularReprojectionConfidence)
{
    // Relaxing normal weights 
    // and if specular reprojection confidence is low
    float relaxation = lerp(1.0, specularReprojectionConfidence, gNormalEdgeStoppingRelaxation);
    float f = 0.9 + 0.1 * saturate(numFramesInHistory / 5.0) * relaxation;

    // This is the main parameter - cone angle
    float angle = getSpecularLobeHalfAngle(roughness);

    // Increasing angle ~10x to relax rejection of the neighbors if specular reprojection confidence is low
    angle *= 3.0 - 2.666 * relaxation * saturate(numFramesInHistory / 5.0);
    angle = min(0.5 * PI, angle);

    // Mitigate banding introduced by errors caused by normals being stored in octahedral 8+8 (Oct16) format
    // See http://jcgt.org/published/0003/02/01/ "A Survey of Efficient Representations for Independent Unit Vectors"
    angle += 0.94 * PI / 180.0;

    return float2(angle, f);
}

float getSpecularNormalWeight(float2 params0, float3 n0, float3 n)
{
    // Assuming that "n0" is normalized and "n" is not!
    float cosa = saturate(dot(n0, n));// *STL::Math::Rsqrt(STL::Math::LengthSquared(n)));
    float a = acos(cosa);
    a = 1.0 - smoothStep(0.0, params0.x, a);

    return saturate(1.0 + (a - 1.0) * params0.y);
}

// Unpacking from LogLuv to RGB is expensive, so let's do it once,
// at the stage of populating the shared memory
uint4 packIlluminationAndVariance(float4 specularIlluminationAndVariance, float4 diffuseIlluminationAndVariance)
{
	uint4 result;
    result.r = f32tof16(specularIlluminationAndVariance.r) | f32tof16(specularIlluminationAndVariance.g) << 16;
	result.g = f32tof16(specularIlluminationAndVariance.b) | f32tof16(specularIlluminationAndVariance.a) << 16;
    result.b = f32tof16(diffuseIlluminationAndVariance.r) | f32tof16(diffuseIlluminationAndVariance.g) << 16;
	result.a = f32tof16(diffuseIlluminationAndVariance.b) | f32tof16(diffuseIlluminationAndVariance.a) << 16;
	return result;
}

void unpackIlluminationAndVariance(uint4 packed, out float4 specularIllum, out float4 diffuseIllum)
{
	specularIllum.r = f16tof32(packed.r);
	specularIllum.g = f16tof32(packed.r >> 16);
    specularIllum.b = f16tof32(packed.g);
    specularIllum.a = f16tof32(packed.g >>16);
	diffuseIllum.r = f16tof32(packed.b);
	diffuseIllum.g = f16tof32(packed.b >> 16);
    diffuseIllum.b = f16tof32(packed.a);
    diffuseIllum.a = f16tof32(packed.a >>16);
}

// computes a 3x3 gaussian blur of the variance, centered around
// the current pixel
void computeVariance(int2 groupThreadId, out float specularVariance, out float diffuseVariance)
{
    float specularSum = 0;
    float diffuseSum = 0;

    const float kernel[2][2] =
    {
        { 1.0 / 4.0, 1.0 / 8.0  },
        { 1.0 / 8.0, 1.0 / 16.0 }
    };

    const int radius = 1;
    for (int yy = -radius; yy <= radius; yy++)
    {
        for (int xx = -radius; xx <= radius; xx++)
        {
            int2 sharedMemoryIndex = groupThreadId.xy + int2(1 + xx, 1 + yy);
            float4 specularIlluminationAndVariance;
            float4 diffuseIlluminationAndVariance;
            unpackIlluminationAndVariance(sharedPackedIlluminationAndVariance[sharedMemoryIndex.y][sharedMemoryIndex.x], specularIlluminationAndVariance, diffuseIlluminationAndVariance);
            float k = kernel[abs(xx)][abs(yy)];
            specularSum += specularIlluminationAndVariance.a * k;
            diffuseSum += diffuseIlluminationAndVariance.a * k;
        }
    }
    specularVariance = specularSum;
    diffuseVariance = diffuseSum;
}

float kernelWeight3x3(float index)
{
	float distanceFromCenter = abs(index);
	return (1.0 - 0.5*distanceFromCenter);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID, uint3 groupThreadId : SV_GroupThreadID, uint3 groupId : SV_GroupID)
{
    //if (any(dispatchThreadId.xy >= gResolution)) return;

    const int2 ipos = dispatchThreadId.xy;

    // Populating shared memory
    //
	// Renumerating threads to load 18x18 (16+2 x 16+2) block of data to shared memory
	//
	// The preloading will be done in two stages:
	// at the first stage the group will load 16x16 / 18 = 14.2 rows of the shared memory,
	// and all threads in the group will be following the same path.
	// At the second stage, the rest 18x18 - 16x16 = 68 threads = 2.125 warps will load the rest of data

	uint linearThreadIndex = groupThreadId.y * 16 + groupThreadId.x;
	uint newIdxX = linearThreadIndex % 18;
	uint newIdxY = linearThreadIndex / 18;

    uint blockXStart = groupId.x * 16;
    uint blockYStart = groupId.y * 16;

	// First stage
	int ox = newIdxX;
	int oy = newIdxY;
	int xx = blockXStart + newIdxX - 1;
	int yy = blockYStart + newIdxY - 1;

    uint4 packedIlluminationAndVariance = 0;
    float3 normal = 0;
    float roughness = 1.0;
    float4 worldPos = 0;
    float depth = 1.0;

	if ((xx >= 0) && (yy >= 0) && (xx < gResolution.x) && (yy < gResolution.y))
	{
        packedIlluminationAndVariance = packIlluminationAndVariance(gSpecularIlluminationAndVariance[int2(xx,yy)], gDiffuseIlluminationAndVariance[int2(xx,yy)]);
        UnpackNormalRoughnessDepth(normal, roughness, depth, gNormalRoughnessDepth[int2(xx, yy)]);
        worldPos = float4(getCurrentWorldPos(int2(xx,yy), depth), 0);
	}
    sharedPackedIlluminationAndVariance[oy][ox] = packedIlluminationAndVariance;
    sharedNormalRoughness[oy][ox] = float4(normal, roughness);
    sharedWorldPos[oy][ox] = worldPos;

	// Second stage
	linearThreadIndex += 16 * 16;
	newIdxX = linearThreadIndex % 18;
	newIdxY = linearThreadIndex / 18;

	ox = newIdxX;
	oy = newIdxY;
	xx = blockXStart + newIdxX - 1;
	yy = blockYStart + newIdxY - 1;

    packedIlluminationAndVariance = 0;
    normal = 0;
    roughness = 1.0;
    worldPos = 0;
    depth = 1.0;

	if (linearThreadIndex < 18 * 18)
	{
        if ((xx >= 0) && (yy >= 0) && (xx < gResolution.x) && (yy < gResolution.y))
	    {
            packedIlluminationAndVariance = packIlluminationAndVariance(gSpecularIlluminationAndVariance[int2(xx, yy)], gDiffuseIlluminationAndVariance[int2(xx, yy)]);
            UnpackNormalRoughnessDepth(normal, roughness, depth, gNormalRoughnessDepth[int2(xx, yy)]);
            worldPos = float4(getCurrentWorldPos(int2(xx, yy), depth), 0);
        }
        sharedPackedIlluminationAndVariance[oy][ox] = packedIlluminationAndVariance;
        sharedNormalRoughness[oy][ox] = float4(normal, roughness);
        sharedWorldPos[oy][ox] = worldPos;
	}

    // Ensuring all the writes to shared memory are done by now
    GroupMemoryBarrierWithGroupSync();

    //
    // Shared memory is populated now and can be used for filtering
    //
    uint2 sharedMemoryIndex = groupThreadId.xy + int2(1,1);

    // Fetching center data
    float3 centerNormal = sharedNormalRoughness[sharedMemoryIndex.y][sharedMemoryIndex.x].rgb;
    float3 centerWorldPos = sharedWorldPos[sharedMemoryIndex.y][sharedMemoryIndex.x].rgb;
    float specularReprojectionConfidence = gSpecularReprojectionConfidence[ipos];

    uint4 centerPackedIlluminationAndVariance = sharedPackedIlluminationAndVariance[sharedMemoryIndex.y][sharedMemoryIndex.x];
    float4 centerSpecularIlluminationAndVariance;
    float4 centerDiffuseIlluminationAndVariance;
    unpackIlluminationAndVariance(centerPackedIlluminationAndVariance, centerSpecularIlluminationAndVariance, centerDiffuseIlluminationAndVariance);

    // Calculating center luminance
    float centerSpecularLuminance = STL::Color::Luminance(centerSpecularIlluminationAndVariance.rgb);
    float centerDiffuseLuminance = STL::Color::Luminance(centerDiffuseIlluminationAndVariance.rgb);

    // Center roughness
    float centerRoughness = sharedNormalRoughness[sharedMemoryIndex.y][sharedMemoryIndex.x].a;
    float2 roughnessWeightParams = getRoughnessWeightParams(centerRoughness, specularReprojectionConfidence);

    float2 normalWeightParams = getNormalWeightParams(centerRoughness, gHistoryLength[ipos], specularReprojectionConfidence);


    // Calculating variance, filtered using 3x3 gaussin blur
    float centerSpecularVar;
    float centerDiffuseVar;
    computeVariance(groupThreadId.xy, centerSpecularVar, centerDiffuseVar);

    float specularPhiLIllumination = 1.0e-4 + gSpecularPhiLuminance * sqrt(max(0.0, centerSpecularVar));
    float diffusePhiLIllumination = 1.0e-4 + gDiffusePhiLuminance * sqrt(max(0.0, centerDiffuseVar));
    float phiDepth = gPhiDepth;

    float sumWSpecular = 0;
    float4 sumSpecularIlluminationAndVariance = 0;

    float sumWDiffuse = 0;
    float4 sumDiffuseIlluminationAndVariance = 0;

    static float kernelWeightGaussian3x3[2] = { 0.44198, 0.27901 };

    //[unroll]
    for (int cy = -1; cy <= 1; cy++)
    {
        //[unroll]
        for (int cx = -1; cx <= 1; cx++)
        {
            const float kernel = kernelWeightGaussian3x3[abs(cx)] * kernelWeightGaussian3x3[abs(cy)]; 
            const int2 p = ipos + int2(cx, cy);
            const bool isInside = all(p >= int2(0, 0)) && all(p < gResolution);
            const bool isCenter = ((cx == 0) && (cy == 0));

            int2 sampleSharedMemoryIndex = groupThreadId.xy + int2(1 + cx, 1 + cy);
                        
            float3 sampleNormal = sharedNormalRoughness[sampleSharedMemoryIndex.y][sampleSharedMemoryIndex.x].rgb;
            float sampleRoughness = sharedNormalRoughness[sampleSharedMemoryIndex.y][sampleSharedMemoryIndex.x].a;
            float3 sampleWorldPos = sharedWorldPos[sampleSharedMemoryIndex.y][sampleSharedMemoryIndex.x].rgb;

            uint4 samplePackedIlluminationAndVariance = sharedPackedIlluminationAndVariance[sampleSharedMemoryIndex.y][sampleSharedMemoryIndex.x];
            float4 sampleSpecularIlluminationAndVariance;
            float4 sampleDiffuseIlluminationAndVariance;
            unpackIlluminationAndVariance(samplePackedIlluminationAndVariance, sampleSpecularIlluminationAndVariance, sampleDiffuseIlluminationAndVariance);

            float sampleSpecularLuminance = STL::Color::Luminance(sampleSpecularIlluminationAndVariance.rgb);
            float sampleDiffuseLuminance = STL::Color::Luminance(sampleDiffuseIlluminationAndVariance.rgb);

            // Calculating geometry and normal weights
            float geometryW = getGeometryWeight(centerWorldPos, centerNormal, sampleWorldPos, phiDepth);

            float normalWSpecular = getSpecularNormalWeight(normalWeightParams, centerNormal, sampleNormal);
            float normalWDiffuse = getDiffuseNormalWeight(centerNormal, sampleNormal, gPhiNormal);

            // Calculating luminande weigths
            float specularLuminanceW = abs(centerSpecularLuminance - sampleSpecularLuminance) / specularPhiLIllumination;
            float relaxation = lerp(1.0, specularReprojectionConfidence, gLuminanceEdgeStoppingRelaxation);
            specularLuminanceW *= relaxation;

            float diffuseLuminanceW = abs(centerDiffuseLuminance - sampleDiffuseLuminance) / diffusePhiLIllumination;

            // Calculating bilateral weight for specular
            float wSpecular =  isCenter ? kernel : kernel * max(1e-6, normalWSpecular * exp(-geometryW - specularLuminanceW)) * getRoughnessWeight(roughnessWeightParams, sampleRoughness);

            // Calculating bilateral weight for diffuse
            float wDiffuse = isCenter ? kernel : max(1e-6, normalWDiffuse * exp(-geometryW - diffuseLuminanceW)) * kernel;

            // Discarding out of screen samples
            wSpecular *= isInside ? 1.0 : 0.0;
            wDiffuse *= isInside ? 1.0 : 0.0;

            // alpha channel contains the variance, therefore the weights need to be squared, see paper for the formula
            sumWSpecular += wSpecular;
            sumSpecularIlluminationAndVariance += float4(wSpecular.xxx, wSpecular * wSpecular) * sampleSpecularIlluminationAndVariance;

            sumWDiffuse += wDiffuse;
            sumDiffuseIlluminationAndVariance += float4(wDiffuse.xxx, wDiffuse * wDiffuse) * sampleDiffuseIlluminationAndVariance;
        }
    }

    // renormalization is different for variance, check paper for the formula
    float4 filteredSpecularIlluminationAndVariance = float4(sumSpecularIlluminationAndVariance / float4(sumWSpecular.xxx, sumWSpecular * sumWSpecular));
    float4 filteredDiffuseIlluminationAndVariance = float4(sumDiffuseIlluminationAndVariance / float4(sumWDiffuse.xxx, sumWDiffuse * sumWDiffuse));

    gOutSpecularIlluminationAndVariance[ipos] = filteredSpecularIlluminationAndVariance;
    gOutDiffuseIlluminationAndVariance[ipos] = filteredDiffuseIlluminationAndVariance;
}