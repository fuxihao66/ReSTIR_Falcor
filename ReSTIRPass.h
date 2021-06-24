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
#pragma once

#include <vector>

#include "Falcor.h"
#include "FalcorExperimental.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "RenderGraph/RenderPassHelpers.h"

//#include "Params.h"


#define SPP 4

using namespace Falcor;


struct EmitterParams {
    uint numEmitterTriangles;
    uint stEmitterIndex;
    uint numEmitters;

};

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



class ReSTIRPass : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<ReSTIRPass>;



    ReSTIRPass();

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual std::string getDesc() override { return "Insert pass description here"; }
    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    //virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override {}
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }








    //Compute


    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;


    
protected:
    // Ray tracing program.
    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
    } mReservoirTracing;

    ComputePass::SharedPtr    mpSpatialPass;
    FullScreenPass::SharedPtr mpShadingPass;


    Texture::SharedPtr mpPrevWorld = nullptr;
    Texture::SharedPtr mpPrevNorm = nullptr;



    Scene::SharedPtr                mpScene;
    SampleGenerator::SharedPtr  mpSampleGenerator;          ///< GPU sample generator.


    Sampler::SharedPtr mpLinearSampler;


    EmitterParams mEmitterParams;
    std::vector<uint2> mEmitterToMeshData;
    std::vector<float> emitterIntensitiesData;

    float totalIntensity;


    Fbo::SharedPtr mpFbo;

    uint mFrameCount = 0;


    Buffer::SharedPtr mpEmitterToMesh;
    Buffer::SharedPtr emitterIntensities;
    Buffer::SharedPtr mpResv;
    Buffer::SharedPtr mpHisResv;
    Buffer::SharedPtr mpTempResv;

    void ProcessScene();
    void PrepareShader();
    void PrepareResources();
    
    bool over = false;
    //ReSTIRPass() = default;
};
