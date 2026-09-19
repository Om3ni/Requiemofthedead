#version 110

varying vec3 vertColour;
varying vec3 vertNormal;
varying vec2 texCoords;

uniform sampler2D Texture;
uniform float Alpha;
uniform vec3 TintColour;

void main()
{
    vec4 texSample = texture2D(Texture, texCoords);
    if(texSample.w < 0.01)
    {
        discard;
    }

    vec3 colour = texSample.xyz * TintColour;
    gl_FragColor = vec4(Alpha * colour * vertColour, Alpha * texSample.w);
}
