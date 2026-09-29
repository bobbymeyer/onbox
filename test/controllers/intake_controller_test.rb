require "test_helper"

class IntakeControllerTest < ActionDispatch::IntegrationTest
  test "rejects unknown tokens" do
    post intake_url, params: { summary: "x" }, as: :json, headers: { "Authorization" => "Bearer nope" }
    assert_response :unauthorized
  end

  test "accepts a hook payload with a bearer token" do
    assert_difference "Card.count" do
      post intake_url, params: { session_id: "s", hook_event_name: "Stop", cwd: "/x/proj" }, as: :json,
        headers: { "Authorization" => "Bearer claude-code-test-token" }
    end
    assert_response :accepted
    assert_equal "proj", Card.last.project
  end

  test "accepts the token as a query parameter" do
    post intake_url(token: "printer-test-token"), params: { summary: "Print done" }, as: :json
    assert_response :accepted
  end

  test "rotating a token retires the old one" do
    source = sources(:printer)
    post rotate_source_url(source)
    assert_redirected_to sources_url

    post intake_url(token: "printer-test-token"), params: { summary: "x" }, as: :json
    assert_response :unauthorized
    post intake_url(token: source.reload.token), params: { summary: "x" }, as: :json
    assert_response :accepted
  end
end
