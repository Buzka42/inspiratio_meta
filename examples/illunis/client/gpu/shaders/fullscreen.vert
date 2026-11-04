// One oversized triangle that covers the render target.
// Vertex buffer: (-1,-1), (3,-1), (-1,3). v_uv is screen uv with y down
// (0 = top), the same convention as FlutterFragCoord / uSize in water.frag.
in vec2 position;
out vec2 v_uv;

void main() {
  v_uv = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
  gl_Position = vec4(position, 0.0, 1.0);
}
