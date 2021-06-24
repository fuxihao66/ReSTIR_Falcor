#include "Utils/Math/MathConstants.slangh"
import Utils.Color.ColorHelpers;

#define PI 3.1415926

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


Texture2D<float4> gWorldPosition;
Texture2D<float4> gWorldShadingNormal;
Texture2D<float4> gWorldFaceNormal;
Texture2D<float4> gMaterialDiffuseOpacity;
Texture2D<float4> gMaterialSpecularRoughness;
Texture2D<float4> gMaterialEmissive;
Texture2D<float4> gMaterialExtraParams;

Texture2D gMotionVec;

RWStructuredBuffer<Reservoir> gResv;



cbuffer CB
{
    uint2 texDim;
    float3 camPosW;
};


float3 brdf(in float3 inVec, in float3 outVec, in float3 normal, in float3 diffuseColor, in float3 spec, in float roughness){

    float3 diffusePart = diffuseColor / PI;

    float NoH = dot(normal, normalize(inVec+outVec));
    float roughnessSqr = roughness*roughness;
    float d = ( NoH * roughnessSqr - NoH ) * NoH + 1;
    float D = roughnessSqr / ( PI * d * d);


    float VoH = dot(inVec, normalize(inVec+outVec));
    float Fc = pow( 1 - VoH, 5 );					
	float3 F = saturate( 50.0 * spec.g ) * Fc + (1 - Fc) * spec;

    float NoV = dot(normal, inVec);
    float NoL = dot(normal, outVec);

    float temp = ( roughness + 1 ) / 2;
    float k = temp * temp * 0.5;
	float Vis_SchlickV = NoV * (1 - k) + k;
	float Vis_SchlickL = NoL * (1 - k) + k;
	float GT = ( Vis_SchlickV * Vis_SchlickL );

    float3 specularPart = D*F*GT / (4 * NoV * NoL);
    // return 1.0;

    return diffusePart + specularPart;
}

float G(in float cosTheta, in float cosGamma, in float dist){
    return abs(cosTheta * cosGamma) / (dist * dist);
}

float4 main(float2 texC : TEXCOORD) : SV_TARGET0
{
    uint WIDTH = texDim.x;
    uint HEIGHT = texDim.y;
    float2 pos = texC * texDim;
    int2 ipos = int2(pos);


    const float4 worldPos = gWorldPosition[ipos];

    
    const float3 albedo = gMaterialDiffuseOpacity[ipos].xyz;
    const float4 specRough = gMaterialSpecularRoughness[ipos];
    const float3 specularColor = specRough.xyz;
    const float roughness = specRough.w;

    const float3 normalW = gWorldShadingNormal[ipos].xyz;


    const float3 cameraRay = normalize(camPosW - worldPos.xyz);


    const float factor = 1000;

    float3 result = float3(0.0, 0.0, 0.0);
    for (uint c = 0; c < 4; c++){
        Reservoir r = gResv[ c * WIDTH * HEIGHT  + ipos.y * WIDTH + ipos.x];
        float3 dirLocal = r.sampledPos - worldPos.xyz;
        float distLocal = length(dirLocal);
        dirLocal /= distLocal;


        result += r.W * r.radiance * factor* brdf(cameraRay, dirLocal, normalW, albedo, specularColor, roughness) * G(dot(normalW, dirLocal), dot(r.lightNormal, dirLocal), distLocal);


        // debug
        // if (r.W > 1e-4)
        //     result += float3(1.0, 1.0, 1.0);

        // result += float3(r.W, r.W, r.W);
        // result += gResv[ c * WIDTH * HEIGHT  + ipos.y * WIDTH + ipos.x].radiance;
    }
    result /= 4;


    return float4(result, 0);
}
