/***************************************************************************
 # Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "ReSTIRPass.h"

// Don't remove this. it's required for hot-reload to function properly
extern "C" __declspec(dllexport) const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" __declspec(dllexport) void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerClass("ReSTIRPass", "Render Pass Template", ReSTIRPass::create);
}

using ChannelList = std::vector<ChannelDesc>;



namespace
{
    const char kShadingShaderFileName[] = "RenderPasses/ReSTIRPass/Shading.ps.slang";
    const char kSpatialShaderFileName[] = "RenderPasses/ReSTIRPass/SpatialUpdate.cs.slang";
    const char kRTShaderFile[] = "RenderPasses/ReSTIRPass/SamplePlusTemporal.rt.slang";

    const std::string kColorOut = "colorOutNoisy";

    uint ScreenWidth = 1280;
    uint ScreenHeight = 720;

    // Ray tracing settings that affect the traversal stack size.
    // These should be set as small as possible.
    const uint32_t kMaxPayloadSizeBytes = 80u;
    const uint32_t kMaxAttributesSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    //const char kViewDirInput[] = "viewW";

    const ChannelList kInputChannels =
    {
        //{ "vbuffer",        "gVBuffer",                   "V buffer"                                                 },
        //{ "viewW",          "gWorldView",                 "View Direction in World"                                  },

        { "posW",           "gWorldPosition",             "World-space position (xyz) and foreground flag (w)"       },
        { "normalW",        "gWorldShadingNormal",        "World-space shading normal (xyz)"                         },
        //{ "tangentW",       "gWorldShadingTangent",       "World-space shading tangent (xyz) and sign (w)", true /* optional */ },
        { "faceNormalW",    "gWorldFaceNormal",           "Face normal in world space (xyz)",                        },


        // 注意需要特别定义texture类型
        { "motionVec",      "gMotionVec",                 "Motion Vectors"       , true /* optional */, ResourceFormat::RG32Float                },

        { "mtlDiffOpacity", "gMaterialDiffuseOpacity",    "Material diffuse color (xyz) and opacity (w)"             },
        { "mtlSpecRough",   "gMaterialSpecularRoughness", "Material specular color (xyz) and roughness (w)"          },
        { "mtlEmissive",    "gMaterialEmissive",          "Material emissive color (xyz)"                            },
        { "mtlParams",      "gMaterialExtraParams",       "Material parameters (IoR, flags etc)"                     },
    };

    //const ChannelList kOutputChannels =
    //{
    //    { "color",          "gOutputColor",               "Output color (sum of direct and indirect)"                },
    //};
};





ReSTIRPass::SharedPtr ReSTIRPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ReSTIRPass);
    return pPass;
}

ReSTIRPass::ReSTIRPass() {
    PrepareShader();
    PrepareResources();
}



Dictionary ReSTIRPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection ReSTIRPass::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    //reflector.addOutput("dst");
    //reflector.addInput("src");
    addRenderPassInputs(reflector, kInputChannels);

    reflector.addOutput(kColorOut, "Before Denoising Output").format(ResourceFormat::RGBA32Float);
    
    return reflector;
}

void ReSTIRPass::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;


    // TODO: addDefine   包括什么：sceneDefine和generator
    // TODO: 同时要setScene
    //mReservoirTracing.pProgram->addDefines(pScene->getSceneDefines());


    RtProgram::Desc progDesc;
    progDesc.addShaderLibrary(kRTShaderFile).setRayGen("rayGen");
    progDesc.addHitGroup(0, "ShadowClosestHit").addMiss(0, "ShadowMiss");
    progDesc.setMaxTraceRecursionDepth(5);

    progDesc.addDefines(pScene->getSceneDefines());

    mReservoirTracing.pProgram = RtProgram::create(progDesc);



    mReservoirTracing.pProgram->addDefines(mpSampleGenerator->getDefines());


    mReservoirTracing.pVars = RtProgramVars::create(mReservoirTracing.pProgram, mpScene);

    mReservoirTracing.pProgram->setScene(mpScene);


    auto pGlobalVars = mReservoirTracing.pVars->getRootVar();
    bool success = mpSampleGenerator->setShaderData(pGlobalVars);
    if (!success) throw std::exception("Failed to bind sample generator");

    
    mpSpatialPass->getProgram()->addDefines(mpSampleGenerator->getDefines());
    //mpSpatialPass->getProgram()->addDefines(pScene->getSceneDefines());   //如果使用gScene需要增加这一定义
    mpSpatialPass->setVars(ComputeVars::create(mpSpatialPass->getProgram().get()));
    success = mpSampleGenerator->setShaderData(mpSpatialPass->getRootVar());
    if (!success) throw std::exception("Failed to bind sample generator");



    ProcessScene();
}

void ReSTIRPass::ProcessScene() {


    // set up receiver/emitter mesh index
    uint32_t offset = 0;

    uint32_t numMeshInstance = mpScene->getMeshInstanceCount();

    mEmitterParams.numEmitters = 0;
    mEmitterParams.numEmitterTriangles = 0;
    mEmitterToMeshData.clear();

    for (uint32_t i = 0; i < numMeshInstance; i++)
    {
        const MeshInstanceData& inst = mpScene->getMeshInstance(i);
        const MeshDesc& mesh = mpScene->getMesh(inst.meshID);
        const auto& mat = mpScene->getMaterial(inst.materialID);

        /*if (mat->isEmissive())
        {
            mEmitterParams.stEmitterIndex = i;
            break;
        }*/

        //offset += mesh.vertexCount;
        

        if (mat->isEmissive()) {

            auto texPtr = mat->getEmissiveTexture();  // TODO: 有些光源用emissive texture？？
            if (texPtr != nullptr)
                std::cout << "emissive texture not null emissive index is " << i << std::endl;
            float3 rgb = mat->getEmissiveColor();   
            if (rgb.r == 0.0 && rgb.g == 0.0 && rgb.b == 0.0)
                continue;

            
            mEmitterParams.numEmitters += 1;


            std::cout << "emissive index is " << i << std::endl;
            std::cout << "num emitter triangles is " << mesh.indexCount / 3 << std::endl;
            mEmitterParams.numEmitterTriangles += mesh.indexCount / 3;

            for (uint j = 0; j < mesh.indexCount / 3; j++)
            {
                mEmitterToMeshData.push_back(uint2(i, j));   // mesh索引, 三角形索引（一个mesh多个三角形）
            }
        }

    }
    {
        //= numMeshInstance - mEmitterParams.stEmitterIndex;

            /*mEmitterParams.numEmitterTriangles = 0;
            mEmitterToMeshData.clear();
            for (uint32_t i = mEmitterParams.stEmitterIndex; i < mEmitterParams.stEmitterIndex + mEmitterParams.numEmitters / 2; i++)
            {
                const MeshInstanceData& inst = mpScene->getMeshInstance(i);
                const MeshDesc& mesh = mpScene->getMesh(inst.meshID);

                mEmitterParams.numEmitterTriangles += mesh.indexCount / 3;
                for (uint j = 0; j < mesh.indexCount / 3; j++)
                {
                    mEmitterToMeshData.push_back(uint2(i, j));
                }
            }*/
    }
     


    if (mpEmitterToMesh) mpEmitterToMesh = nullptr;
    mpEmitterToMesh = Buffer::createStructured(sizeof(uint2), mEmitterToMeshData.size());
    mpEmitterToMesh->setBlob((void*)(mEmitterToMeshData.data()), 0, mEmitterToMeshData.size() * sizeof(uint2));


    emitterIntensitiesData.clear();
    totalIntensity = 0.0f;
    for (uint i = 0; i < mEmitterToMeshData.size(); i++) {
        float r, g, b;
        const MeshInstanceData& inst = mpScene->getMeshInstance(mEmitterToMeshData[i].x);
        const auto& mat = mpScene->getMaterial(inst.materialID);
        float3 rgb = mat->getEmissiveColor();
        r = rgb.x; g = rgb.y; b = rgb.z;
        float intensity = 0.299 * r + 0.587 * g + 0.114 * b;

        

        totalIntensity += intensity;

        emitterIntensitiesData.push_back(totalIntensity); // 注意是累计intensity和

    }


    if (emitterIntensities) emitterIntensities = nullptr;
    emitterIntensities = Buffer::createStructured(sizeof(float), emitterIntensitiesData.size());
    emitterIntensities->setBlob((void*)(emitterIntensitiesData.data()), 0, emitterIntensitiesData.size() * sizeof(float));
}

// resv: intensity normal  p w x
void ReSTIRPass::PrepareResources() {

    mpResv = Buffer::createStructured(sizeof(Reservoir), SPP * ScreenWidth * ScreenHeight);
    mpHisResv = Buffer::createStructured(sizeof(Reservoir), SPP * ScreenWidth * ScreenHeight);
    mpTempResv = Buffer::createStructured(sizeof(Reservoir), SPP * ScreenWidth * ScreenHeight);
    
    mpFbo = Fbo::create();
}

void ReSTIRPass::PrepareShader() {
    mpShadingPass = FullScreenPass::create(kShadingShaderFileName);

    
    auto desc = Program::Desc();
    desc.addShaderLibrary(kSpatialShaderFileName).csEntry("SpatialUpdate").setShaderModel("6_3");
    mpSpatialPass = ComputePass::create(desc, Program::DefineList(), false);

    {

        // Create ray tracing program.
        /*RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kRTShaderFile).setRayGen("rayGen");
        progDesc.addHitGroup(0, "ShadowClosestHit").addMiss(0, "ShadowMiss");
        progDesc.setMaxTraceRecursionDepth(2);
        mReservoirTracing.pProgram = RtProgram::create(progDesc);*/


        //mReservoirTracing.pProgram = RtProgram::create(progDesc, kMaxPayloadSizeBytes, kMaxAttributesSizeBytes);
    }
    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    assert(mpSampleGenerator);



    Sampler::Desc samplerDesc;
    samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    samplerDesc.setBorderColor(Falcor::float4(0, 0, 0, 0));
    mpLinearSampler = Sampler::create(samplerDesc);


    
}

// 需要的资源   gbuffer，两个resv，light2mesh

void ReSTIRPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{

    if (mpPrevWorld == nullptr)
    {
        const auto& pColorOut = renderData[kColorOut]->asTexture();

        mpPrevWorld = Texture::create2D(pColorOut->getWidth(), pColorOut->getHeight(), pColorOut->getFormat(), 1, 1, nullptr, Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
        mpPrevNorm = Texture::create2D(pColorOut->getWidth(), pColorOut->getHeight(), pColorOut->getFormat(), 1, 1, nullptr, Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
    }

    const int sampleNum = 50;

    //// TODO: 所有绑定都需要提前define
    mReservoirTracing.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mpSpatialPass->getProgram()->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mpShadingPass->getProgram()->addDefines(getValidResourceDefines(kInputChannels, renderData));



    const uint2 targetDim = renderData.getDefaultTextureDims();



    mFrameCount += 1;

    

    // stage 1  RIS+SHADOW+Temporal
    auto pGlobalVars = mReservoirTracing.pVars->getRootVar();  
     
    // 绑定GBuffer中的纹理
    auto bindRT = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            pGlobalVars[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto channel : kInputChannels) bindRT(channel);


    pGlobalVars["gPrevWorldPosition"] = mpPrevWorld;
    pGlobalVars["gPrevWorldShadingNormal"] = mpPrevNorm;


    pGlobalVars["gEmitterIntensities"] = emitterIntensities;

    pGlobalVars["CB"]["gFrameCount"] = mFrameCount;  // 如果frameCount不够  就只用spatial
    pGlobalVars["CB"]["TotalIntensity"] = totalIntensity;
    pGlobalVars["CB"]["SAMPLE_NUM"] = sampleNum;
    pGlobalVars["CB"]["emitterPara"].setBlob(mEmitterParams);

    pGlobalVars["gSampler"] = mpLinearSampler;

    std::string st = "gHisResv";
    pGlobalVars[st] = mpHisResv;

    std::string st1 = "gResv";
    pGlobalVars[st1] = mpResv;

    
    pGlobalVars["gEmitterToMesh"] = mpEmitterToMesh;

    // gRtScene, gScene 变量会自动bind, scene->render也会自动bind
    // 但是对于compute pass，gScene还是要手动绑定
    mpScene->raytrace(pRenderContext, mReservoirTracing.pProgram.get(), mReservoirTracing.pVars, uint3(targetDim, 1));

    
    // if (mFrameCount == 15) {
    //     const Reservoir* resvData = reinterpret_cast<const Reservoir*>(mpResv->map(Buffer::MapType::Read));
    //     mpResv->unmap();


    //     FILE* fp = fopen("C:/Users/admin/Desktop/PersonalProject/paperReimpl/areaLighting/ReSTIRPass/debug_temporal.txt", "w");
    //     for (size_t i = 0; i < ScreenHeight * ScreenWidth * SPP; i++) {
    //         fprintf(fp, "W = %f\n", resvData[i].W);
    //     }

    //     fclose(fp);
    // }

    
    
    float3 camPosW = mpScene->getCamera()->getPosition();


#if 1
    // stage 2  spatial
    // 绑定GBuffer中的纹理
    auto bindSpatial = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            mpSpatialPass[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto channel : kInputChannels) bindSpatial(channel);
    //mpSpatialPass["gScene"] = mpScene->getParameterBlock();

    mpSpatialPass["CB"]["texDim"] = targetDim;
    mpSpatialPass["CB"]["camPosW"] = camPosW;
    mpSpatialPass["CB"]["gFrameCount"] = mFrameCount;

    for (uint i = 0; i < 1; i++) {
        mpSpatialPass["gResv"] = mpResv;
        mpSpatialPass["gTargetResv"] = mpTempResv;

        mpSpatialPass->execute(pRenderContext, uint3(targetDim, 1));

        auto temp = mpTempResv;
        mpTempResv = mpResv;
        mpResv = temp;   

    }



    
    // if (mFrameCount == 15) {
    //     const Reservoir* resvData = reinterpret_cast<const Reservoir*>(mpResv->map(Buffer::MapType::Read));
    //     mpResv->unmap();


    //     FILE* fp = fopen("C:/Users/admin/Desktop/PersonalProject/paperReimpl/areaLighting/ReSTIRPass/debug_spatial.txt", "w");
    //     for (size_t i = 0; i < ScreenHeight * ScreenWidth * SPP; i++) {
    //         fprintf(fp, "W = %f\n", resvData[i].W);
    //     }

    //     fclose(fp);
    // }

#endif // 0

    // stage 3  shading
    auto bindShading = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            mpShadingPass[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto channel : kInputChannels) bindShading(channel);
    mpShadingPass["gResv"] = mpResv;

    //mpShadingPass["gScene"] = mpScene->getParameterBlock();  // TODO: 必须要在define里面添加scene define


    //float3 camPosW = mpScene->getCamera()->getPosition();
    mpShadingPass["CB"]["texDim"] = targetDim;
    mpShadingPass["CB"]["camPosW"] = camPosW;


    const auto& pColorOut = renderData[kColorOut]->asTexture();
    mpFbo->attachColorTarget(pColorOut, 0);

    mpShadingPass->execute(pRenderContext, mpFbo);

    
    


    // current to history
    auto tempResv = mpResv;
    mpResv = mpHisResv;
    mpHisResv = tempResv;
        
    

    pRenderContext->blit(renderData["posW"]->getSRV(), mpPrevWorld->getRTV());
    pRenderContext->blit(renderData["normalW"]->getSRV(), mpPrevNorm->getRTV());
    
}

void ReSTIRPass::renderUI(Gui::Widgets& widget)
{
}
