#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;

Texture2D<float4> gWorldPosition;
Texture2D<float4> gWorldShadingNormal;
// Texture2D<float4> gWorldShadingTangent; // Optional
Texture2D<float4> gWorldFaceNormal;
// Texture2D<float4> gWorldView; // Optional
Texture2D<float4> gMaterialDiffuseOpacity;
Texture2D<float4> gMaterialSpecularRoughness;
Texture2D<float4> gMaterialEmissive;
Texture2D<float4> gMaterialExtraParams;

Texture2D<float2> gMotionVec;


struct Reservoir {
    float3  radiance;
    float   intensity;
    float3  lightNormal;
    float   weightSum;
    float   phat;
    float3  sampledPos;
    uint    M;
    float   W;    // algo 3  line 8
};
// SamplerState gSampler_linear;
// SamplerState gSampler_point;

RWStructuredBuffer<Reservoir> gResv;
RWStructuredBuffer<Reservoir> gTargetResv;

cbuffer CB
{
    uint2 texDim;
    float3 camPosW;
    uint gFrameCount;
};
#define PI 3.1415926


float3 brdf(in float3 inVec, in float3 outVec, in float3 normal, in float3 diffuseColor, in float3 spec, in float roughness){

    // float3 diffusePart = diffuseColor / PI;

    float NoH = dot(normal, normalize(inVec+outVec));
    float roughnessSqr = roughness*roughness;
    float d = ( NoH * roughnessSqr - NoH ) * NoH + 1;
    float D = roughnessSqr / ( PI * d * d);

    return abs(D);
}

// float3 brdf(in float3 inVec, in float3 outVec, in float3 normal, in float3 diffuseColor, in float3 spec, in float roughness){

//     float3 diffusePart = diffuseColor / PI;

//     float NoH = dot(normal, normalize(inVec+outVec));
//     float roughnessSqr = roughness*roughness;
//     float d = ( NoH * roughnessSqr - NoH ) * NoH + 1;
//     float D = roughnessSqr / ( PI * d * d);


//     float VoH = dot(inVec, normalize(inVec+outVec));
//     float Fc = pow( 1 - VoH, 5 );					
// 	float3 F = saturate( 50.0 * spec.g ) * Fc + (1 - Fc) * spec;

//     float NoV = dot(normal, inVec);
//     float NoL = dot(normal, outVec);

//     float temp = ( roughness + 1 ) / 2;
//     float k = temp * temp * 0.5;
// 	float Vis_SchlickV = NoV * (1 - k) + k;
// 	float Vis_SchlickL = NoL * (1 - k) + k;
// 	float GT = ( Vis_SchlickV * Vis_SchlickL );

//     float3 specularPart = D*F*GT / (4 * NoV * NoL);
//     // return 1.0;

//     return diffusePart + specularPart;
// }

float G(in float cosTheta, in float cosGamma, in float dist){
    return abs(cosTheta * cosGamma) / (dist * dist);
}
void UpdateReservoir(inout Reservoir r, in float3 x, in float weight, in float3 radiance, in float3 lightNormal, in SampleGenerator sg){
    r.weightSum = r.weightSum + weight;
    r.M = r.M + 1;

    float rndPoint = sampleNext1D(sg);

    if (rndPoint < weight / r.weightSum){
        r.sampledPos    = x;
        r.radiance      = radiance;
        r.lightNormal   = lightNormal;
        r.intensity     = 0.299 * radiance.x + 0.587 * radiance.y + 0.114 * radiance.z;
    }
}

void CombineResv(inout Reservoir reservOut, in Reservoir reservTemp,in SampleGenerator sg, in float3 normalW, in float3 worldPos, in float3 cameraRay, in float3 albedo, in float3 specularColor, in float roughness){
    float revTempWeight = reservTemp.phat * reservTemp.W * reservTemp.M;
    UpdateReservoir(reservOut, reservTemp.sampledPos, revTempWeight, reservTemp.radiance, reservTemp.lightNormal, sg);

}



#define KERNEL_SIZE 3

[numthreads(1, 1, 1)]
void SpatialUpdate(uint3 id : SV_DispatchThreadID)
{
    int _FrameWidth = texDim.x;
    int _FrameHeight = texDim.y;

    uint2 launchIndex = id.xy;

    if (launchIndex.x >= _FrameWidth || launchIndex.y >= _FrameHeight)
        return;

    int2 pixel = launchIndex.xy;
    float2 uv = pixel / (float2(_FrameWidth, _FrameHeight) - 1.0);
    float2 halfTexel = 1.0 / float2(_FrameWidth, _FrameHeight) / 2.0;


    
    const float4 worldPos = gWorldPosition[launchIndex];

    
    const float3 albedo = gMaterialDiffuseOpacity[launchIndex].xyz;
    const float4 specRough = gMaterialSpecularRoughness[launchIndex];
    const float3 specularColor = specRough.xyz;
    const float roughness = specRough.w;
    const float3 normalW = gWorldShadingNormal[launchIndex].xyz;
    const float3 cameraRay = normalize(camPosW - worldPos.xyz);
    


    SampleGenerator sg = SampleGenerator.create(launchIndex, gFrameCount);


    if (worldPos.w == 0.f){
        for (uint c = 0; c < 4; c++){
            int centerLinearIndex = c * _FrameWidth * _FrameHeight + pixel.y * _FrameWidth + pixel.x;
            gTargetResv[centerLinearIndex].W = 0.0;
        }
        return;

    }
    for (uint c = 0; c < 4; c++){
        uint MSum = 0;

        int centerLinearIndex = c * _FrameWidth * _FrameHeight + pixel.y * _FrameWidth + pixel.x;

        gTargetResv[centerLinearIndex].M = 0;
        gTargetResv[centerLinearIndex].W = 0;
        gTargetResv[centerLinearIndex].weightSum = 0;
        for (int i = -1; i <= KERNEL_SIZE/2; i++){
            for (int j = -1; j <= KERNEL_SIZE/2; j++){
                
                int2 ids = pixel + int2(i, j);
                if (ids.x >=  _FrameWidth || ids.y >= _FrameHeight || ids.x < 0 || ids.y < 0)
                    continue;
                
                int neighLinearIndex = c * _FrameWidth * _FrameHeight + ids.y * _FrameWidth + ids.x;

                CombineResv(gTargetResv[centerLinearIndex], gResv[neighLinearIndex], sg, normalW, worldPos.xyz, cameraRay,albedo, specularColor, roughness);

                MSum += gResv[neighLinearIndex].M;
            }
        }
        gTargetResv[centerLinearIndex].M = MSum;


        
        float3 spw = gTargetResv[centerLinearIndex].sampledPos;
        float3 dir = spw - worldPos.xyz;
        float dist = length(dir);
        dir = dir / dist;
        float3 brdfVal = brdf(cameraRay, dir, normalW, albedo, specularColor, roughness);
        float brdfVal1C = 0.299 * brdfVal.x + 0.587 * brdfVal.y + 0.114 * brdfVal.z;
        gTargetResv[centerLinearIndex].phat = gTargetResv[centerLinearIndex].intensity * brdfVal1C * G(dot(normalW, dir), dot(gTargetResv[centerLinearIndex].lightNormal, dir), dist);


        gTargetResv[centerLinearIndex].W = gTargetResv[centerLinearIndex].weightSum / ( gTargetResv[centerLinearIndex].M * gTargetResv[centerLinearIndex].phat );
    }
    
    
}
