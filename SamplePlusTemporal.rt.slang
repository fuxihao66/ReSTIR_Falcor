/*
hybrid rendering大坑：光栅化后的world position不准确，导致shadow ray可能打到光线起点所在的三角形

*/




#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Experimental.Scene.Material.MaterialShading;
import Experimental.Scene.Lights.LightHelpers;

import Scene.HitInfo;
// import Utils.Timing.GpuTimer;
import Scene.Scene;
// import RenderPasses.Shared.PathTracer.PixelStats;
// import RenderPasses.Shared.PathTracer.PathTracerHelpers;
// import RenderPasses.Shared.PathTracer.InteriorListHelpers;
// import RenderPasses.Shared.PathTracer.RayFootprint;
// import Utils.Debug.PixelDebug;

#define PI 3.1415926

struct gEmitterParams {
    uint numEmitterTriangles;
    uint stEmitterIndex;
    uint numEmitters;

};


// TODO: struct 定义统一 （共用定义？）

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

cbuffer CB
{
    uint            gFrameCount;        // Frame count since scene was loaded.
    gEmitterParams  emitterPara;
    float           TotalIntensity;
    uint            SAMPLE_NUM;
};

// Inputs
Texture2D<float4> gWorldPosition;
Texture2D<float4> gWorldShadingNormal;
// Texture2D<float4> gWorldShadingTangent; // Optional
Texture2D<float4> gWorldFaceNormal;
// Texture2D<float4> gWorldView; // Optional
Texture2D<float4> gMaterialDiffuseOpacity;
Texture2D<float4> gMaterialSpecularRoughness;
Texture2D<float4> gMaterialEmissive;
Texture2D<float4> gMaterialExtraParams;



Texture2D<float4> gPrevWorldPosition;
Texture2D<float4> gPrevWorldShadingNormal;



Texture2D<float2> gMotionVec;


SamplerState gSampler;


RWStructuredBuffer<Reservoir> gResv;
RWStructuredBuffer<Reservoir> gHisResv;



Buffer<uint2> gEmitterToMesh;
Buffer<float> gEmitterIntensities;


/** Payload for shadow ray.
*/
struct RayData
{
    bool intersected;
    float dist;
    float3 rayOrigin;
};



[shader("miss")]
void ShadowMiss(inout RayData rayData)
{
    rayData.intersected = false;

}



[shader("closesthit")]
void ShadowClosestHit(
    uniform HitShaderParams hitParams,
    inout RayData rayData, in BuiltInTriangleIntersectionAttributes attribs)
{
    rayData.intersected = true;

    // Evaluate Falcor's material parameters at the hit point.
    // TODO: Implement texLOD to enable texture filtering in prepareShadingData().
    VertexData v = getVertexData(hitParams, PrimitiveIndex(), attribs);


    rayData.dist = length(v.posW - rayData.rayOrigin);
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


// 更新方法有问题    
    // reservTemp.W可能为0  reservHis.W可能为0
void CombineResv(inout Reservoir reservOut, in Reservoir reservTemp, in Reservoir reservHis, in SampleGenerator sg, in float3 normalW, in float3 worldPos, in float3 cameraRay, in float3 albedo, in float3 specularColor, in float roughness){
    


    reservOut = reservTemp;
    reservOut.weightSum = reservTemp.phat * reservTemp.W * reservTemp.M;
    // float revTempWeight = reservTemp.phat * reservTemp.W * reservTemp.M;
    // UpdateReservoir(reservOut, reservTemp.sampledPos, revTempWeight, reservTemp.radiance, reservTemp.lightNormal, sg);

    float revHisWeight = reservHis.phat * reservHis.W * reservHis.M;
    UpdateReservoir(reservOut, reservHis.sampledPos, revHisWeight, reservHis.radiance, reservHis.lightNormal, sg);

    reservOut.M = reservTemp.M + reservHis.M;



    float3 spw = reservOut.sampledPos;
    float3 dir = spw - worldPos.xyz;
    float dist = length(dir);
    dir = dir / dist;

    float3 brdfVal = brdf(cameraRay, dir, normalW, albedo, specularColor, roughness);

    float brdfVal1C = 0.299 * brdfVal.x + 0.587 * brdfVal.y + 0.114 * brdfVal.z;


    reservOut.phat = reservOut.intensity * brdfVal1C * G(dot(normalW, dir), dot(reservOut.lightNormal, dir), dist);
    
    reservOut.W = (reservOut.weightSum / reservOut.M) / (reservOut.phat);



    // reservOut.W = (reservTemp.W + reservHis.W ) / 2.0;
    // 去除shadow部分后，其他部分也变亮？   因为反面的光源也算了进去
    // reservOut = reservTemp;
    // //TODO: debug   这应该和不用history结果一样 但是实际上却偏亮
    // reservOut.phat = reservTemp.phat;
    // // reservOut.W = (reservOut.weightSum / reservOut.M) / (reservTemp.phat);// TODO: debug   reservTemp.phat很小？
    // reservOut.W = (reservTemp.weightSum / reservTemp.M) / (reservTemp.phat);// TODO: debug   reservTemp.phat很小？
    // if (reservTemp.W == 0.0)
    //     reservOut.W = 0.0;
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
float3 brdf(in float3 inVec, in float3 outVec, in float3 normal, in float3 diffuseColor, in float3 spec, in float roughness){

    // float3 diffusePart = diffuseColor / PI;

    float NoH = dot(normal, normalize(inVec+outVec));
    float roughnessSqr = roughness*roughness;
    float d = ( NoH * roughnessSqr - NoH ) * NoH + 1;
    float D = roughnessSqr / ( PI * d * d);

    return abs(D);

}

float G(in float cosTheta, in float cosGamma, in float dist){
    return abs(cosTheta * cosGamma) / (dist * dist);
}


// RIS: 通过不断重采样出一堆样本，这个过程采出的样本会逐渐服从需要的phat分布  （目的和MIS一样  只是手段不一样）
// WRS: 从一堆样本中采出一部分   可以大大减少样本数



// TODO: 
// 两个问题：
// 1. temporal复用检查不对  检查一下（cabinet左边的阴影）
// 2. motion vector不准？导致一动就在边缘处变亮？   phat和brdf有关（albedo？），所以如果前一帧对应是poster左边缘墙壁，当前帧是post上，则weightSum偏大，但reservOut.phat偏小，最终结果偏大
// phat是brdf*Le*G   这里的brdf指的是归一化的lobe（这里用了UE的brdf，因此直接用NDF D）   phat只是算权重用的
// 最终算出来的W就是MC积分中的1/p（p\approx phat）  RIS+WIS就是要得到服从phat分布的样本
[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;


    const uint WIDTH = launchDim.x; 
    const uint HEIGHT = launchDim.y; 

    const int SPP = 4;


    const float4 worldPos = gWorldPosition[launchIndex];


    // float2 uv = (float2(launchIndex) + float2(0.5, 0.5) ) / float2(launchDim);
    // const float4 worldPos = gWorldPosition.SampleLevel(gSampler, uv, 0);


    
    const float3 albedo = gMaterialDiffuseOpacity[launchIndex].xyz;
    const float4 specRough = gMaterialSpecularRoughness[launchIndex];
    const float3 specularColor = specRough.xyz;
    const float roughness = specRough.w;


    
    const float3 normalW = gWorldShadingNormal[launchIndex].xyz;

    const float3 camPosW = gScene.camera.getPosition();

    const float3 cameraRay = normalize(camPosW - worldPos.xyz);

    
    if (worldPos.w != 0.f)  // Using w to indicate valid geometry 
    {


        // for (uint i = 0; i < gPRNGDimension; i++) sampleNext1D(sg);



        Reservoir r[4];


        SampleGenerator sg = SampleGenerator.create(launchIndex, gFrameCount);
        // SampleGenerator sg = SampleGenerator.create(uint2(233, 233), 1);


        for (uint c = 0; c < SPP; c++){
            
            // Create sample generator.



            r[c].W = 0.0;   // TODO: 初始化很重要
            r[c].weightSum = 0.0;
            r[c].M = 0;
            
            for (uint i = 0; i < SAMPLE_NUM; i++){
                // 根据intensity选择光源
                // 在选择的光源上随机取点
                float uniform01 = sampleNext1D(sg);
                float intensityRange = uniform01 * TotalIntensity;
                int sampledLightIndex = -1;


                // 随机选取一个光源
                // TODO: 应该根据intensity来选光源
                sampledLightIndex = max(uniform01 * emitterPara.numEmitterTriangles - 0.5, 0); 
                // sampledLightIndex = uniform01 * 959; 
                // TODO: 随机采样算法修改
                // int startIndex = 0;
                // int endIndex = emitterPara.numEmitterTriangles - 1;
                // while (startIndex < endIndex){
                //     int midIndex = (startIndex + endIndex) / 2;
                //     if (gEmitterIntensities[midIndex] >= intensityRange){
                //         endIndex = midIndex;
                //     }
                //     else{
                //         startIndex = midIndex;
                //     }
                // }
                // sampledLightIndex = startIndex;
               
                float r0 = sampleNext1D(sg);
                float r1 = sampleNext1D(sg);
                uint2 emitterMeshIndex = gEmitterToMesh[sampledLightIndex];
                float3 lightPos[3];
                gScene.getVertexPositionsW(emitterMeshIndex.x, emitterMeshIndex.y, lightPos);

                float3 v1 = (lightPos[1] - lightPos[0]);
                float3 v2 = (lightPos[2] - lightPos[0]);
                float3 p1 = lightPos[0] + r0 * v1 + r1 * v2;
                float3 p2 = lightPos[0] + (1-r0)*v1 + (1-r1)*v2;
                float3 p = length(lightPos[0] - p1) > length(lightPos[0] - p2) ? p2 : p1;

                float l0 = length(lightPos[1] - lightPos[2] );
                float l1 = length(v1);
                float l2 = length(v2);
                float halfC = (l0+l1+l2)/2.0;
                float area = sqrt(halfC*(halfC-l0)*(halfC-l1)*(halfC-l2));

                MeshDesc desc = gScene.getMeshDesc(emitterMeshIndex.x);
                float3 Le = gScene.materials[desc.materialID].emissive;


                float3 lightNorm = normalize(cross(v1, v2));


                float3 dirLocal = p - worldPos.xyz;
                float distLocal = length(dirLocal);
                dirLocal /= distLocal;


                float3 brdfVal = brdf(cameraRay, dirLocal, normalW, albedo, specularColor, roughness);

                float brdfVal1C = 0.299 * brdfVal.x + 0.587 * brdfVal.y + 0.114 * brdfVal.z;

                // if (sampledLightIndex == 0)
                //     UpdateReservoir(r[c], p, (0.299 * Le.x + 0.587 * Le.y + 0.114 * Le.z) * brdfVal1C * G(dot(normalW, dirLocal), dot(lightNorm, dirLocal), distLocal) * gScene.getFaceAreaW(emitterMeshIndex.x, emitterMeshIndex.y) * TotalIntensity / gEmitterIntensities[sampledLightIndex], Le, lightNorm, sg );
                // else
                //     UpdateReservoir(r[c], p, (0.299 * Le.x + 0.587 * Le.y + 0.114 * Le.z) * brdfVal1C * G(dot(normalW, dirLocal), dot(lightNorm, dirLocal), distLocal) * gScene.getFaceAreaW(emitterMeshIndex.x, emitterMeshIndex.y) * TotalIntensity / (gEmitterIntensities[sampledLightIndex] - gEmitterIntensities[sampledLightIndex-1]), Le, lightNorm, sg );

                UpdateReservoir(r[c], p, (0.299 * Le.x + 0.587 * Le.y + 0.114 * Le.z) * brdfVal1C * G(dot(normalW, dirLocal), dot(lightNorm, dirLocal), distLocal) * gScene.getFaceAreaW(emitterMeshIndex.x, emitterMeshIndex.y) * emitterPara.numEmitterTriangles, Le, lightNorm, sg );
                 
            }



            // 2. 对采样点进行trace
            float3 spw = r[c].sampledPos;
            float3 dir = spw - worldPos.xyz;
            float dist = length(dir);
            dir = dir / dist;


            float3 brdfVal = brdf(cameraRay, dir, normalW, albedo, specularColor, roughness);

            float brdfVal1C = 0.299 * brdfVal.x + 0.587 * brdfVal.y + 0.114 * brdfVal.z;

            r[c].phat = r[c].intensity * brdfVal1C * G(dot(normalW, dir), dot(r[c].lightNormal, dir), dist);
            r[c].W = 1.0/(r[c].phat) *(r[c].weightSum / r[c].M);  
            


            const float3 origin = worldPos.xyz + 1e-4*dir; // 光栅化导致worldPos在实际三角形的下方，导致shadow ray打到自己
            RayDesc ray;
            ray.Origin = origin;
            ray.Direction = dir;
            ray.TMin = 0.f;
            ray.TMax = FLT_MAX;

            uint rayFlags = 0;     

            RayData rayData;
            rayData.rayOrigin = origin;
            TraceRay(gRtScene, rayFlags, 0xff , 0 , hitProgramCount, 0 , ray, rayData);
            // // 用第一组hit miss group （只有一组）
            if (rayData.intersected && rayData.dist <= dist - 1e-3 ){
                r[c].W = 0.0;

                
            }
            // else
            //     r[c].W = 1.0;  // TODO: for debug
            
        

            gResv[c* WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x] = r[c];



            // 3. 历史resv进行blend
            if ( gFrameCount < 7){
                continue;
            }


            Reservoir rTemp;
            rTemp.W = 0.0;   // TODO: 初始化很重要
            rTemp.weightSum = 0.0;
            rTemp.M = 0;


            float2 mvPixel = gMotionVec.Load(int3(launchIndex, 0)).xy;
            if (abs(mvPixel.x) < 2e-5) // 
                mvPixel.x = 0.0;
            if (abs(mvPixel.y) < 2e-5) // 
                mvPixel.y = 0.0;

            // float2 mvPixel = gMotionVec[launchIndex].xy;//*launchDim
            uint2 oldpixelPos = uint2(launchIndex.x + mvPixel.x*WIDTH, launchIndex.y + mvPixel.y*HEIGHT);

            uint oldPixelPos1D = c * WIDTH * HEIGHT + oldpixelPos.y * WIDTH + oldpixelPos.x;
            

            float3 prevWorldPos = gPrevWorldPosition[oldpixelPos].rgb;
            float3 prevNormal = gPrevWorldShadingNormal[oldpixelPos].rgb;
            if (length(worldPos.xyz - prevWorldPos) > 1.0 || dot(prevNormal, normalW) < 0.95){
                // gResv[c* WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x].W = 0.0;
                continue;

            }


            CombineResv(rTemp, r[c], gHisResv[oldPixelPos1D], sg, normalW, worldPos.xyz, cameraRay,albedo, specularColor, roughness);

            gResv[c * WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x] = rTemp;
            
            
            // gResv[c * WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x].W = 1.0/(r[c].phat) *(r[c].weightSum / r[c].M);// TODO: debug  
            // gResv[c * WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x].W = r[c].W;// TODO: debug  
            

            // TODO: debug
            // gResv[c* WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x] =  gHisResv[oldPixelPos1D];
            // gResv[c* WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x].W =  gMotionVec.Load(int3(launchIndex, 0)).x*10;

        }
        
       
        
        


    }  
    else{
        for (uint c = 0; c < 4; c++)
            gResv[c* WIDTH * HEIGHT + launchIndex.y * WIDTH + launchIndex.x].W = 0.0;
    }  

}
