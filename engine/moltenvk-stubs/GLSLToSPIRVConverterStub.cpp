// Stand-in for MoltenVK's GLSLToSPIRVConverter.cpp, written for this build so that glslang is
// not needed. It implements the class declared in GLSLToSPIRVConverter.h, but conversion
// always fails with a clear message. Only MoltenVK's own "GLSL shader module" extension
// reaches this code; Wine, DXVK and vkd3d pass SPIR-V.
#include <MoltenVKShaderConverter/GLSLToSPIRVConverter.h>

using namespace mvk;

void GLSLToSPIRVConverter::setGLSL(const std::string& glslSrc) {
	_glsls.clear();
	_glsls.push_back(glslSrc);
}

void GLSLToSPIRVConverter::setGLSL(const char* glslSrc, size_t length) {
	_glsls.clear();
	_glsls.emplace_back(glslSrc, length);
}

void GLSLToSPIRVConverter::setGLSLs(const std::vector<std::string>& glslSrcs) {
	_glsls = glslSrcs;
}

bool GLSLToSPIRVConverter::convert(MVKGLSLConversionShaderStage, GLSLToSPIRVConversionResult& conversionResult,
								   bool, bool) {
	conversionResult.spirv.clear();
	conversionResult.resultLog = "GLSL to SPIR-V conversion is not available in this MoltenVK build.";
	return false;
}
