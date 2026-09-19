#version 330

layout (location = 0) in vec4 vertex;
layout (location = 1) in vec4 normal;
layout (location = 2) in vec4 boneWeights;
layout (location = 3) in vec4 boneIndices;
layout (location = 4) in vec2 uv;

out vec3 vertColour;
out vec3 vertNormal;
out vec2 texCoords;

uniform mat4 ModelViewProjection;
uniform float targetDepth = 0.5;
uniform float DepthBias;
uniform mat4 MatrixPalette[60];
uniform vec2 UVScale = vec2(1,1);
uniform float HighResDepthMultiplier = 0.0;
uniform float FinalScale = 1.0;

void main()
{
    vec4 position = vec4(vertex.xyz, 1.0);
    vec4 skinnedNormal = vec4(normal.xyz, 0.0);

    texCoords = uv * UVScale.xy;

    mat4 boneEffect = mat4(0.0);
    if(boneWeights.x > 0.0)
        boneEffect += MatrixPalette[int(boneIndices.x)] * boneWeights.x;
    if(boneWeights.y > 0.0)
        boneEffect += MatrixPalette[int(boneIndices.y)] * boneWeights.y;
    if(boneWeights.z > 0.0)
        boneEffect += MatrixPalette[int(boneIndices.z)] * boneWeights.z;
    if(boneWeights.w > 0.0)
        boneEffect += MatrixPalette[int(boneIndices.w)] * boneWeights.w;

    skinnedNormal = boneEffect * skinnedNormal;
    vertNormal = skinnedNormal.xyz;
    vertColour = vec3(1.0);

    vec4 positionScaled = boneEffect * position;
    positionScaled.xyz *= FinalScale;
    vec4 projected = ModelViewProjection * positionScaled;

    vec4 origin = ModelViewProjection * vec4(0, 0, 0, 1);
    projected.z += (origin.z - projected.z) * HighResDepthMultiplier;

    float clip = ((projected.z + 1.0) / 2.0);
    clip += targetDepth - 0.5;
    projected.z = (clip * 2.0) - 1.0;

    gl_Position = projected;
}
