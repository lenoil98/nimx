import types
import opengl
import unsigned
import logging
import matrixes

export matrixes

type ShaderAttribute = enum
    saPosition
    aaFillColor


type Transform3D* = Matrix4

const vertexShader = """
attribute vec4 position;

uniform mat4 modelViewProjectionMatrix;

void main()
{
    gl_Position = modelViewProjectionMatrix * position;
}
"""

const fragmentShader = """
#ifdef GL_ES
precision mediump float;
#endif

uniform vec4 fillColor;

void main()
{
	gl_FragColor = fillColor;
}
"""

const roundedRectVertexShader = """
attribute vec4 position;

uniform mat4 modelViewProjectionMatrix;

varying vec2 vertCoord;

void main()
{
    vertCoord = position.xy;
    gl_Position = modelViewProjectionMatrix * position;
}
"""

const roundedRectFragmentShader = """
#ifdef GL_ES
precision mediump float;
#extension GL_OES_standard_derivatives : enable
#endif

uniform vec4 fillColor;
uniform float radius;
uniform vec4 rect;

varying vec2 vertCoord;

float udRoundBox(vec2 p, vec2 b, float r)
{
    return length(max(abs(p)-b+r,0.0))-r;
}

void main(void)
{
    // setup
    vec2 halfRes = rect.zw * 0.5;

    // compute box
    float b = udRoundBox(vertCoord.xy - rect.xy - halfRes + 0.0, halfRes - fwidth(vertCoord.xy) * 1.0, radius );
	float margin = fwidth(b);
    float alpha = 1.0 - smoothstep(0.0, margin,b);
    gl_FragColor = vec4(fillColor.xyz, fillColor.w * alpha);
}
"""

const ellipseFragmentShader = """
#ifdef GL_ES
precision mediump float;
#extension GL_OES_standard_derivatives : enable
#endif

uniform vec4 fillColor;
uniform vec4 strokeColor;
uniform vec4 rect;
uniform float strokeWidth;

varying vec2 vertCoord;

void main()
{
    vec2 ab = rect.zw / 2.0;
	vec2 center = rect.xy + ab;
    vec2 pos = vertCoord  - center;
    pos *= pos;
    float outerDist = dot(pos, 1.0 / (ab * ab));

	ab -= strokeWidth / 2.0;
    float innerDist = dot(pos, 1.0 / (ab * ab));
    float outerDelta = fwidth(outerDist) * 0.8;
    float innerDelta = fwidth(innerDist) * 0.8;

    float innerAlpha = smoothstep(1.0 - innerDelta, 1.0 + innerDelta, innerDist);
    float outerAlpha = smoothstep(1.0 - outerDelta, 1.0 + outerDelta, outerDist);

    gl_FragColor = mix(strokeColor, vec4(0, 0, 0, 0), outerAlpha);
	gl_FragColor = mix(fillColor, gl_FragColor, innerAlpha);
    /*
    vec2 ab = rect.zw / 2.0;
	vec2 center = rect.xy + ab;
    vec2 pos = vertCoord - center;
    float dist = pos.x*pos.x/(ab.x*ab.x) + pos.y*pos.y/(ab.y*ab.y);
    float delta = fwidth(dist) * 0.8;
    float alpha = 1.0 - smoothstep(1.0 - delta, 1.0 + delta, dist);
    gl_FragColor = vec4(fillColor.xyz, fillColor.w * alpha);
    */
}

"""

proc getShaderInfoLog(s: GLuint): string =
    var infoLen: GLint
    result = ""
    glGetShaderiv(s, GL_INFO_LOG_LENGTH, addr infoLen)
    if infoLen > 0:
        var infoLog : cstring = cast[cstring](alloc(infoLen + 1))
        glGetShaderInfoLog(s, infoLen, nil, infoLog)
        result = $infoLog
        dealloc(infoLog)

proc getProgramInfoLog(s: GLuint): string =
    var infoLen: GLint
    result = ""
    glGetProgramiv(s, GL_INFO_LOG_LENGTH, addr infoLen)
    if infoLen > 0:
        var infoLog : cstring = cast[cstring](alloc(infoLen + 1))
        glGetProgramInfoLog(s, infoLen, nil, infoLog)
        result = $infoLog
        dealloc(infoLog)

proc loadShader(shaderSrc: string, kind: GLenum): GLuint =
    result = glCreateShader(kind)
    if result == 0:
        return

    # Load the shader source
    var srcArray = [shaderSrc.cstring]
    glShaderSource(result, 1, cast[cstringArray](addr srcArray), nil)
    # Compile the shader
    glCompileShader(result)
    # Check the compile status
    var compiled: GLint
    glGetShaderiv(result, GL_COMPILE_STATUS, addr compiled)
    let info = getShaderInfoLog(result)
    if compiled == 0:
        log "Shader compile error: ", info
        glDeleteShader(result)
    elif info.len > 0:
        log "Shader compile log: ", info

proc newShaderProgram(vs, fs: string): GLuint =
    result = glCreateProgram()
    if result == 0:
        log "Could not create program: ", glGetError()
        return
    var s = loadShader(vs, GL_VERTEX_SHADER)
    if s == 0:
        glDeleteProgram(result)
        return 0
    glAttachShader(result, s)
    s = loadShader(fs, GL_FRAGMENT_SHADER)
    if s == 0:
        glDeleteProgram(result)
        return 0
    glAttachShader(result, s)
    glLinkProgram(result)
    var linked : GLint
    glGetProgramiv(result, GL_LINK_STATUS, addr linked)
    let info = getProgramInfoLog(result)
    if linked == 0:
        log "Could not link: ", info
        result = 0
    elif info.len > 0:
        log "Program linked: ", info
    result.glBindAttribLocation(GLuint(saPosition), "position")

type PrimitiveType* = enum
    ptTriangles = GL_TRIANGLES
    ptTriangleStrip = GL_TRIANGLE_STRIP
    ptTriangleFan = GL_TRIANGLE_FAN

type GraphicsContext* = ref object of RootObj
    #transform*: Transform3D
    pTransform: ptr Transform3D
    fillColor*: Color
    strokeColor*: Color
    strokeWidth*: Coord
    shaderProgram: GLuint
    roundedRectShaderProgram: GLuint
    ellipseShaderProgram: GLuint

var gCurrentContext: GraphicsContext

template setScopeTransform*(c: GraphicsContext, t: var Transform3D): expr =
    let old = c.pTransform
    c.pTransform = addr t
    old

template revertTransform*(c: GraphicsContext, t: ptr Transform3D) =
    c.pTransform = t

proc setTransform*(c: GraphicsContext, t: var Transform3D): ptr Transform3D {.discardable.}=
    result = c.pTransform
    c.pTransform = addr t

proc setTransform*(c: GraphicsContext, t: ptr Transform3D): ptr Transform3D {.discardable.} =
    result = c.pTransform
    c.pTransform = t

template transform*(c: GraphicsContext): expr = c.pTransform[]

proc newGraphicsContext*(): GraphicsContext =
    result.new()
    when not defined(ios) and not defined(android):
        loadExtensions()

    result.shaderProgram = newShaderProgram(vertexShader, fragmentShader)
    result.roundedRectShaderProgram = newShaderProgram(roundedRectVertexShader, roundedRectFragmentShader)
    result.ellipseShaderProgram = newShaderProgram(roundedRectVertexShader, ellipseFragmentShader)
    glClearColor(1.0, 0.0, 1.0, 1.0)


proc setCurrentContext*(c: GraphicsContext): GraphicsContext {.discardable.} =
    result = gCurrentContext
    gCurrentContext = c

proc currentContext*(): GraphicsContext = gCurrentContext

proc drawVertexes*(c: GraphicsContext, componentCount: int, points: openarray[Coord], pt: PrimitiveType) =
    assert(points.len mod componentCount == 0)
    c.shaderProgram.glUseProgram()
    glEnableVertexAttribArray(GLuint(saPosition))
    glVertexAttribPointer(GLuint(saPosition), GLint(componentCount), cGL_FLOAT, false, 0, cast[pointer](points))
    glUniform4fv(glGetUniformLocation(c.shaderProgram, "fillColor"), 1, cast[ptr GLfloat](addr c.fillColor))
    glUniformMatrix4fv(glGetUniformLocation(c.shaderProgram, "modelViewProjectionMatrix"), 1, false, cast[ptr GLfloat](c.pTransform))
    glDrawArrays(cast[GLenum](pt), 0, GLsizei(points.len / componentCount))

proc drawRectAsQuad(c: GraphicsContext, r: Rect) =
    var points = [r.minX, r.minY,
                r.maxX, r.minY,
                r.maxX, r.maxY,
                r.minX, r.maxY]
    let componentCount = 2
    glEnableVertexAttribArray(GLuint(saPosition))
    glVertexAttribPointer(GLuint(saPosition), GLint(componentCount), cGL_FLOAT, false, 0, cast[pointer](addr points))
    glDrawArrays(cast[GLenum](ptTriangleFan), 0, GLsizei(points.len / componentCount))

proc drawRoundedRect*(c: GraphicsContext, r: Rect, radius: Coord) =
    var rect = r
    var rad = radius
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    c.roundedRectShaderProgram.glUseProgram()
    glUniform4fv(glGetUniformLocation(c.roundedRectShaderProgram, "fillColor"), 1, cast[ptr GLfloat](addr c.fillColor))
    glUniformMatrix4fv(glGetUniformLocation(c.roundedRectShaderProgram, "modelViewProjectionMatrix"), 1, false, cast[ptr GLfloat](c.pTransform))
    glUniform4fv(glGetUniformLocation(c.roundedRectShaderProgram, "rect"), 1, cast[ptr GLfloat](addr rect))
    glUniform1fv(glGetUniformLocation(c.roundedRectShaderProgram, "radius"), 1, addr rad)
    c.drawRectAsQuad(r)

proc drawRect*(c: GraphicsContext, r: Rect) =
    let points = [r.minX, r.minY,
                r.maxX, r.minY,
                r.maxX, r.maxY,
                r.minX, r.maxY]
    c.drawVertexes(2, points, ptTriangleFan)

proc drawEllipseInRect*(c: GraphicsContext, r: Rect) =
    var rect = r
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    c.ellipseShaderProgram.glUseProgram()
    glUniform4fv(glGetUniformLocation(c.ellipseShaderProgram, "fillColor"), 1, cast[ptr GLfloat](addr c.fillColor))
    glUniform4fv(glGetUniformLocation(c.ellipseShaderProgram, "strokeColor"), 1, cast[ptr GLfloat](addr c.strokeColor))
    glUniform1fv(glGetUniformLocation(c.ellipseShaderProgram, "strokeWidth"), 1, cast[ptr GLfloat](addr c.strokeWidth))
    glUniformMatrix4fv(glGetUniformLocation(c.ellipseShaderProgram, "modelViewProjectionMatrix"), 1, false, cast[ptr GLfloat](c.pTransform))
    glUniform4fv(glGetUniformLocation(c.ellipseShaderProgram, "rect"), 1, cast[ptr GLfloat](addr rect))
    c.drawRectAsQuad(r)
