/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

NRD_SAMPLER_START
    NRD_SAMPLER( SamplerState, gNearestClamp, s, 0 )
    NRD_SAMPLER( SamplerState, gNearestMirror, s, 1 )
    NRD_SAMPLER( SamplerState, gLinearClamp, s, 2 )
    NRD_SAMPLER( SamplerState, gLinearMirror, s, 3 )
NRD_SAMPLER_END

NRD_CONSTANTS_START
    RELAX_SHARED_CB_DATA
    NRD_CONSTANT( float, gDepthThreshold )
    NRD_CONSTANT( float, gHistoryFixEdgeStoppingNormalPower )
    NRD_CONSTANT( float, gHistoryFixStrideBetweenSamples )
    NRD_CONSTANT( float, gHistoryFixFrameNum )
    #if( defined RELAX_SPECULAR )
        NRD_CONSTANT(float, gSpecularLobeAngleFraction)
        NRD_CONSTANT(float, gSpecularLobeAngleSlack)
        NRD_CONSTANT(float, gRoughnessEdgeStoppingRelaxation)
        NRD_CONSTANT(float, gNormalEdgeStoppingRelaxation)
    #endif
NRD_CONSTANTS_END

#if( defined RELAX_DIFFUSE && defined RELAX_SPECULAR )

    NRD_INPUT_TEXTURE_START
        NRD_INPUT_TEXTURE( Texture2D<float4>, gSpecularIllumination, t, 0 )
        NRD_INPUT_TEXTURE( Texture2D<float4>, gDiffuseIllumination, t, 1 )
        NRD_INPUT_TEXTURE( Texture2D<float>,  gHistoryLength, t, 2 )
        NRD_INPUT_TEXTURE( Texture2D<float4>, gNormalRoughness, t, 3 )
        NRD_INPUT_TEXTURE( Texture2D<float>,  gViewZFP16, t, 4 )
        #ifdef RELAX_SH
            NRD_INPUT_TEXTURE( Texture2D<float4>, gSpecularSH1, t, 5 )
            NRD_INPUT_TEXTURE( Texture2D<float4>, gDiffuseSH1, t, 6 )
        #endif
    NRD_INPUT_TEXTURE_END

    NRD_OUTPUT_TEXTURE_START
        NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutSpecularIllumination, u, 0 )
        NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutDiffuseIllumination, u, 1 )
        #ifdef RELAX_SH
            NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutSpecularSH1, u, 2 )
            NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutDiffuseSH1, u, 3 )
        #endif
    NRD_OUTPUT_TEXTURE_END

#elif( defined RELAX_DIFFUSE )

    NRD_INPUT_TEXTURE_START
        NRD_INPUT_TEXTURE( Texture2D<float4>, gDiffuseIllumination, t, 0 )
        NRD_INPUT_TEXTURE( Texture2D<float>, gHistoryLength, t, 1 )
        NRD_INPUT_TEXTURE( Texture2D<float4>, gNormalRoughness, t, 2 )
        NRD_INPUT_TEXTURE( Texture2D<float>, gViewZFP16, t, 3 )
        #ifdef RELAX_SH
            NRD_INPUT_TEXTURE( Texture2D<float4>, gDiffuseSH1, t, 4 )
        #endif
    NRD_INPUT_TEXTURE_END

    NRD_OUTPUT_TEXTURE_START
        NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutDiffuseIllumination, u, 0 )
        #ifdef RELAX_SH
            NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutDiffuseSH1, u, 1 )
        #endif
    NRD_OUTPUT_TEXTURE_END

#elif( defined RELAX_SPECULAR )

    NRD_INPUT_TEXTURE_START
        NRD_INPUT_TEXTURE( Texture2D<float4>, gSpecularIllumination, t, 0 )
        NRD_INPUT_TEXTURE( Texture2D<float>, gHistoryLength, t, 1 )
        NRD_INPUT_TEXTURE( Texture2D<float4>, gNormalRoughness, t, 2 )
        NRD_INPUT_TEXTURE( Texture2D<float>, gViewZFP16, t, 3 )
        #ifdef RELAX_SH
            NRD_INPUT_TEXTURE( Texture2D<float4>, gSpecularSH1, t, 4 )
        #endif
    NRD_INPUT_TEXTURE_END

    NRD_OUTPUT_TEXTURE_START
        NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutSpecularIllumination, u, 0 )
        #ifdef RELAX_SH
            NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutSpecularSH1, u, 1 )
        #endif
    NRD_OUTPUT_TEXTURE_END

#endif

// Macro magic
#define GROUP_X 8
#define GROUP_Y 8
