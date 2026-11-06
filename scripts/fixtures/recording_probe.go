// Stage 07: real SFU -> recorder/FFmpeg -> S3 audio-only artifact probe.
// Input is valid synthetic Opus silence, not microphone/device capture.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

var stage = "startup"
var client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect") }}

func request(base, token, method, path string, body any, result any) error {
	encoded, err := json.Marshal(body)
	if err != nil {
		return errors.New("encode")
	}
	req, err := http.NewRequest(method, base+"/api/v1"+path, bytes.NewReader(encoded))
	if err != nil {
		return errors.New("request")
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(req)
	if err != nil {
		return errors.New("http")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("http_%d", response.StatusCode)
	}
	if result == nil {
		_, _ = io.Copy(io.Discard, response.Body)
		return nil
	}
	if json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(result) != nil {
		return errors.New("decode")
	}
	return nil
}

func account(base string) (string, error) {
	email, password := uuid.NewString()+"@example.test", uuid.NewString()
	if err := request(base, "", "POST", "/auth/register", map[string]string{"email": email, "password": password, "displayName": "Audio recording pipeline probe"}, nil); err != nil {
		return "", err
	}
	var login struct {
		AccessToken string `json:"accessToken"`
	}
	err := request(base, "", "POST", "/auth/login", map[string]string{"email": email, "password": password}, &login)
	if err != nil || login.AccessToken == "" {
		return "", errors.New("login")
	}
	return login.AccessToken, nil
}

type envelope struct {
	Version      int             `json:"version"`
	ID           string          `json:"id"`
	Type         string          `json:"type"`
	ConferenceID string          `json:"conferenceId"`
	Timestamp    time.Time       `json:"timestamp"`
	Data         json.RawMessage `json:"data"`
	ReplyTo      string          `json:"replyTo,omitempty"`
}

type trackInfo struct {
	ID, StreamID, MediaPeerID, ParticipantID, Kind, Source string
}
type command struct {
	action string
	result chan error
}
type source struct {
	track      *webrtc.TrackLocalStaticSample
	sender     *webrtc.RTPSender
	generation string
}
type peer struct {
	room                                     string
	socket                                   *websocket.Conn
	write                                    sync.Mutex
	pc                                       *webrtc.PeerConnection
	id                                       string
	sources                                  map[string]*source // Event loop owns all SDP/source mutations.
	commands                                 chan command
	events                                   chan envelope
	failures                                 chan error
	done, loopDone                           chan struct{}
	once                                     sync.Once
	workers                                  sync.WaitGroup
	pending, dirty, deferredLocal            bool
	negotiation, offerRequest, expectedError string
	completion                               chan error
	queued                                   []command
	remoteICE                                []webrtc.ICECandidateInit
	mu                                       sync.Mutex
	tracks, published                        map[string]trackInfo
	packets                                  map[string]int64
	negotiations, rejections                 int
	ready                                    bool
}

func (p *peer) send(kind string, data any) (string, error) {
	raw, err := json.Marshal(data)
	if err != nil {
		return "", err
	}
	id := uuid.NewString()
	p.write.Lock()
	defer p.write.Unlock()
	_ = p.socket.SetWriteDeadline(time.Now().Add(5 * time.Second))
	err = p.socket.WriteJSON(envelope{Version: 1, ID: id, Type: kind, ConferenceID: p.room, Timestamp: time.Now().UTC(), Data: raw})
	return id, err
}
func (p *peer) fail(err error) {
	select {
	case p.failures <- err:
	default:
	}
}
func connect(base, token, room string) (*peer, error) {
	var ticket struct {
		Ticket string `json:"ticket"`
	}
	if err := request(base, token, "POST", "/conferences/"+room+"/ws-ticket", map[string]string{"clientId": uuid.NewString()}, &ticket); err != nil {
		return nil, err
	}
	dialer := websocket.Dialer{Subprotocols: []string{"go-recorder.v1"}, HandshakeTimeout: 5 * time.Second}
	socket, _, err := dialer.Dial(strings.Replace(base, "http://", "ws://", 1)+"/api/v1/conferences/"+room+"/ws?ticket="+ticket.Ticket, nil)
	if err != nil {
		return nil, errors.New("websocket")
	}
	p := &peer{room: room, socket: socket, sources: map[string]*source{}, commands: make(chan command), events: make(chan envelope, 64), failures: make(chan error, 4), done: make(chan struct{}), loopDone: make(chan struct{}), tracks: map[string]trackInfo{}, published: map[string]trackInfo{}, packets: map[string]int64{}}
	p.workers.Add(1)
	go func() {
		defer p.workers.Done()
		for {
			var e envelope
			if socket.ReadJSON(&e) != nil {
				select {
				case <-p.done:
				default:
					p.fail(errors.New("socket_read"))
				}
				return
			}
			select {
			case p.events <- e:
			case <-p.done:
				return
			}
		}
	}()
	go func() {
		defer close(p.loopDone)
		if err := p.loop(); err != nil {
			p.fail(err)
		}
	}()
	if _, err = p.send("media.join", map[string]any{}); err != nil {
		p.close(false)
		return nil, err
	}
	return p, nil
}
func (p *peer) addSource(name string) error {
	if p.sources[name] != nil {
		return nil
	}
	codec := webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000}
	if name == "microphone" {
		codec = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}
	}
	stream := p.id
	if name == "video/screen" {
		stream += "-screen"
	}
	generation := uuid.NewString()
	track, err := webrtc.NewTrackLocalStaticSample(codec, generation, stream)
	if err != nil {
		return err
	}
	sender, err := p.pc.AddTrack(track)
	if err != nil {
		return err
	}
	p.sources[name] = &source{track: track, sender: sender, generation: generation}
	p.workers.Add(1)
	go func() {
		defer p.workers.Done()
		buffer := make([]byte, 1500)
		for {
			if _, _, err := sender.Read(buffer); err != nil {
				return
			}
		}
	}()
	return nil
}
func (p *peer) removeSource(name string) error {
	s := p.sources[name]
	if s == nil {
		return nil
	}
	delete(p.sources, name)
	return p.pc.RemoveTrack(s.sender)
}
func (p *peer) prepare(maxPeers int) error {
	engine := &webrtc.MediaEngine{}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1"}, PayloadType: 111}, webrtc.RTPCodecTypeAudio); err != nil {
		return err
	}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000, RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}, {Type: "ccm", Parameter: "fir"}}}, PayloadType: 96}, webrtc.RTPCodecTypeVideo); err != nil {
		return err
	}
	pc, err := webrtc.NewAPI(webrtc.WithMediaEngine(engine)).NewPeerConnection(webrtc.Configuration{BundlePolicy: webrtc.BundlePolicyMaxBundle, SDPSemantics: webrtc.SDPSemanticsUnifiedPlan})
	if err != nil {
		return err
	}
	p.pc = pc
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		var value *webrtc.ICECandidateInit
		if c != nil {
			v := c.ToJSON()
			value = &v
		}
		if _, err := p.send("media.ice", map[string]any{"mediaPeerId": p.id, "candidate": value}); err != nil {
			p.fail(errors.New("ice_send"))
		}
	})
	pc.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		p.workers.Add(1)
		go func() {
			defer p.workers.Done()
			for {
				if _, _, err := track.ReadRTP(); err != nil {
					return
				}
				p.mu.Lock()
				p.packets[track.ID()]++
				p.mu.Unlock()
			}
		}()
	})
	for _, name := range []string{"microphone"} {
		if err = p.addSource(name); err != nil {
			return err
		}
	}
	// Reserve all four source kinds per peer; AddTrack reuses a recvonly video slot.
	for i := 1; i < 4*maxPeers; i++ {
		kind := webrtc.RTPCodecTypeVideo
		if i%4 == 3 || i%4 == 0 {
			kind = webrtc.RTPCodecTypeAudio
		}
		if _, err = pc.AddTransceiverFromKind(kind, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
			return err
		}
	}
	return p.offer(nil, "")
}
func (p *peer) offer(completion chan error, expected string) error {
	if p.pending {
		p.dirty = true
		return nil
	}
	offer, err := p.pc.CreateOffer(nil)
	if err != nil {
		return err
	}
	// Pion v4.2.12 lacks a have-local-offer -> rollback transition. For an expected
	// server rejection only, send a generated offer without applying it locally.
	// This checks server atomicity/recovery, not native rollback implementation.
	if expected == "" {
		if err = p.pc.SetLocalDescription(offer); err != nil {
			return err
		}
	}
	publications := []map[string]string{}
	for name, s := range p.sources {
		mid := ""
		for _, t := range p.pc.GetTransceivers() {
			if t.Sender() == s.sender {
				mid = t.Mid()
				break
			}
		}
		if mid == "" {
			return errors.New("missing_mid")
		}
		publications = append(publications, map[string]string{"mid": mid, "source": name, "trackId": s.generation})
	}
	p.negotiation = uuid.NewString()
	p.pending = true
	p.dirty = false
	p.completion = completion
	p.expectedError = expected
	p.deferredLocal = expected != ""
	p.offerRequest, err = p.send("media.offer", map[string]any{"mediaPeerId": p.id, "negotiationId": p.negotiation, "sdp": offer.SDP, "publications": publications})
	return err
}
func (p *peer) execute(c command) error {
	if p.pending {
		p.queued = append(p.queued, c)
		return nil
	}
	var err error
	expected := ""
	switch c.action {
	case "start":
		err = p.addSource("video/screen")
	case "stop":
		err = p.removeSource("video/screen")
	case "camera":
		err = p.addSource("camera")
	case "conflict":
		err = p.addSource("video/screen")
		expected = "screen_sharing_conflict"
	case "blocked":
		err = p.addSource("video/screen")
		expected = "media_policy_blocked"
	case "offer":
	default:
		return errors.New("unknown_command")
	}
	if err != nil {
		return err
	}
	return p.offer(c.result, expected)
}
func (p *peer) next() error {
	if len(p.queued) > 0 {
		c := p.queued[0]
		p.queued = p.queued[1:]
		return p.execute(c)
	}
	if p.dirty {
		return p.offer(nil, "")
	}
	return nil
}
func (p *peer) loop() error {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-p.done:
			return nil
		case c := <-p.commands:
			if err := p.execute(c); err != nil {
				return err
			}
		case <-ticker.C:
			for name, s := range p.sources {
				if name != "microphone" {
					return errors.New("audio_only_probe")
				}
				sample := []byte{0xf8, 0xff, 0xfe}
				_ = s.track.WriteSample(media.Sample{Data: sample, Duration: 20 * time.Millisecond})
			}
		case e := <-p.events:
			if e.ConferenceID != p.room {
				return errors.New("room_scope")
			}
			var d struct {
				MediaPeerID   string                                                                 `json:"mediaPeerId"`
				MaxPeers      int                                                                    `json:"maxPeers"`
				NegotiationID string                                                                 `json:"negotiationId"`
				SDP           string                                                                 `json:"sdp"`
				Candidate     *webrtc.ICECandidateInit                                               `json:"candidate"`
				Code          string                                                                 `json:"code"`
				Tracks        []trackInfo                                                            `json:"tracks"`
				Track         trackInfo                                                              `json:"track"`
				TrackID       string                                                                 `json:"trackId"`
				Policy        struct{ MicrophoneBlocked, CameraBlocked, ScreenBlocked, Kicked bool } `json:"policy"`
			}
			if json.Unmarshal(e.Data, &d) != nil {
				return errors.New("event_decode")
			}
			switch e.Type {
			case "media.joined":
				if p.pc != nil || d.MaxPeers < 2 || d.MaxPeers > 16 {
					return errors.New("joined")
				}
				p.id = d.MediaPeerID
				if err := p.prepare(d.MaxPeers); err != nil {
					return err
				}
			case "media.answer":
				if !p.pending || d.MediaPeerID != p.id || d.NegotiationID != p.negotiation || e.ReplyTo != p.offerRequest {
					return errors.New("answer_scope")
				}
				if p.deferredLocal {
					return errors.New("expected_offer_rejection")
				}
				if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: d.SDP}); err != nil {
					return errors.New("answer_apply")
				}
				for _, candidate := range p.remoteICE {
					if p.pc.AddICECandidate(candidate) != nil {
						return errors.New("buffered_ice")
					}
				}
				p.remoteICE = nil
				if _, err := p.send("media.ready", map[string]string{"mediaPeerId": p.id, "negotiationId": p.negotiation}); err != nil {
					return errors.New("ready_send")
				}
				p.pending = false
				p.mu.Lock()
				p.negotiations++
				p.ready = true
				p.mu.Unlock()
				if p.completion != nil {
					p.completion <- nil
					p.completion = nil
				}
				if err := p.next(); err != nil {
					return err
				}
			case "media.ice":
				if d.MediaPeerID != p.id {
					continue
				}
				candidate := webrtc.ICECandidateInit{}
				if d.Candidate != nil {
					candidate = *d.Candidate
				}
				if p.pc == nil || p.pc.RemoteDescription() == nil {
					p.remoteICE = append(p.remoteICE, candidate)
				} else if p.pc.AddICECandidate(candidate) != nil {
					return errors.New("remote_ice")
				}
			case "media.renegotiate":
				if d.MediaPeerID == p.id && p.pc != nil {
					if err := p.offer(nil, ""); err != nil {
						return err
					}
				}
			case "media.tracks":
				if d.MediaPeerID != p.id {
					return errors.New("tracks_scope")
				}
				catalog := map[string]trackInfo{}
				for _, t := range d.Tracks {
					suffix := ""
					if strings.HasSuffix(t.Source, "/screen") {
						suffix = "-screen"
					}
					if t.StreamID != t.MediaPeerID+suffix || t.MediaPeerID == p.id {
						return errors.New("track_metadata")
					}
					catalog[t.ID] = t
				}
				p.mu.Lock()
				p.tracks = catalog
				p.mu.Unlock()
			case "media.published":
				p.mu.Lock()
				p.published[d.Track.ID] = d.Track
				p.mu.Unlock()
			case "media.unpublished":
				p.mu.Lock()
				delete(p.published, d.TrackID)
				p.mu.Unlock()
			case "media.policy":
				if d.Policy.Kicked {
					return errors.New("unexpected_kick")
				}
				changed := false
				for name := range p.sources {
					blocked := name == "microphone" && d.Policy.MicrophoneBlocked || name == "camera" && d.Policy.CameraBlocked || name == "video/screen" && (d.Policy.ScreenBlocked || d.Policy.CameraBlocked)
					if blocked {
						if err := p.removeSource(name); err != nil {
							return err
						}
						changed = true
					}
				}
				if changed {
					if err := p.offer(nil, ""); err != nil {
						return err
					}
				}
			case "error", "media.error":
				if !p.pending || !p.deferredLocal || e.ReplyTo != p.offerRequest || d.Code != p.expectedError {
					return errors.New("unexpected_signal_" + d.Code)
				}
				if p.pc.SignalingState() != webrtc.SignalingStateStable {
					return errors.New("expected_stable_local")
				}
				if err := p.removeSource("video/screen"); err != nil {
					return err
				}
				p.pending = false
				p.mu.Lock()
				p.rejections++
				p.mu.Unlock()
				reply := p.completion
				p.completion = nil
				if err := p.offer(reply, ""); err != nil {
					return err
				}
			}
		}
	}
}
func (p *peer) command(action string) error {
	c := command{action: action, result: make(chan error, 1)}
	select {
	case p.commands <- c:
	case err := <-p.failures:
		return err
	case <-time.After(15 * time.Second):
		return errors.New("command_queue_timeout")
	}
	select {
	case err := <-c.result:
		return err
	case err := <-p.failures:
		return err
	case <-time.After(15 * time.Second):
		return errors.New("command_timeout")
	}
}
func (p *peer) sourcePackets(source string) int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	var count int64
	for id, t := range p.tracks {
		if t.Source == source {
			count += p.packets[id]
		}
	}
	return count
}
func (p *peer) hasSource(source string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, t := range p.tracks {
		if t.Source == source {
			return true
		}
	}
	return false
}
func (p *peer) close(abrupt bool) {
	p.once.Do(func() {
		if !abrupt {
			_, _ = p.send("media.leave", map[string]any{})
		}
		close(p.done)
		_ = p.socket.Close()
		<-p.loopDone
		if p.pc != nil {
			_ = p.pc.Close()
		}
		p.workers.Wait()
	})
}
func wait(label string, peers []*peer, test func() bool) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		for _, p := range peers {
			select {
			case err := <-p.failures:
				return fmt.Errorf("%s: %w", label, err)
			default:
			}
		}
		if test() {
			return nil
		}
		time.Sleep(40 * time.Millisecond)
	}
	return errors.New(label + "_timeout")
}

type recording struct {
	UUID, Status, Mode string
	Files              []struct {
		UUID, FileType, FileName, MimeType, URL, ChecksumSHA256 string
		SizeBytes                                               int64
		DurationSec                                             int
	}
}
type recordingResponse struct {
	Item recording `json:"item"`
}

func readRecording(base, token, path string) (recording, error) {
	var response recordingResponse
	err := request(base, token, "GET", path, nil, &response)
	return response.Item, err
}
func awaitRecording(base, token, path, desired string) (recording, error) {
	deadline := time.Now().Add(100 * time.Second)
	last := ""
	for time.Now().Before(deadline) {
		r, err := readRecording(base, token, path)
		if err != nil {
			return r, err
		}
		if r.Status != last {
			fmt.Println("STATE recording=" + r.Status)
			last = r.Status
		}
		if r.Status == desired {
			return r, nil
		}
		if r.Status == "failed" || r.Status == "cancelled" {
			return r, errors.New("recording_terminal_" + r.Status)
		}
		time.Sleep(250 * time.Millisecond)
	}
	return recording{}, errors.New("recording_timeout_" + desired)
}
func denied(err error) bool {
	return err != nil && (err.Error() == "http_403" || err.Error() == "http_404")
}
func run() error {
	base := os.Getenv("MEETSPACE_PROBE_API")
	if !strings.HasPrefix(base, "http://meetspace-ios-recording-") {
		return errors.New("isolated_network_required")
	}
	stage = "accounts"
	tokenA, err := account(base)
	if err != nil {
		return err
	}
	tokenB, err := account(base)
	if err != nil {
		return err
	}
	tokenC, err := account(base)
	if err != nil {
		return err
	}
	var room struct {
		Item struct{ ID, InviteCode string } `json:"item"`
	}
	if err = request(base, tokenA, "POST", "/conferences", map[string]any{"title": "Real audio-only pipeline", "waitingRoomEnabled": false}, &room); err != nil {
		return err
	}
	roomPath := "/conferences/" + room.Item.ID
	var participantB string
	for _, token := range []string{tokenA, tokenB} {
		var m struct {
			Item struct{ ID string } `json:"item"`
		}
		if err = request(base, token, "POST", roomPath+"/join", map[string]string{"inviteCode": room.Item.InviteCode}, &m); err != nil {
			return err
		}
		if token == tokenB {
			participantB = m.Item.ID
		}
	}
	if err = request(base, tokenA, "POST", roomPath+"/start", map[string]any{}, nil); err != nil {
		return err
	}
	stage = "audio_publication"
	publisher, err := connect(base, tokenA, room.Item.ID)
	if err != nil {
		return err
	}
	defer publisher.close(false)
	if err = wait("microphone_publication", []*peer{publisher}, func() bool {
		publisher.mu.Lock()
		defer publisher.mu.Unlock()
		for _, track := range publisher.published {
			if track.Source == "microphone" {
				return publisher.ready
			}
		}
		return false
	}); err != nil {
		return err
	}
	fmt.Println("PASS native Pion Opus source published through real SFU; synthetic silence 20ms packets")
	stage = "record_start"
	var start recordingResponse
	if err = request(base, tokenA, "POST", roomPath+"/recordings", map[string]string{"mode": "audio_only"}, &start); err != nil {
		return err
	}
	if start.Item.UUID == "" || start.Item.Mode != "audio_only" {
		return errors.New("record_start_contract")
	}
	path := roomPath + "/recordings/" + start.Item.UUID
	if _, err = awaitRecording(base, tokenA, path, "recording"); err != nil {
		return err
	}
	if !denied(request(base, tokenB, "POST", path+"/stop", map[string]any{}, nil)) {
		return errors.New("peer_stop_was_not_denied")
	}
	if !denied(request(base, tokenC, "GET", path, nil, nil)) {
		return errors.New("outsider_read_was_not_denied")
	}
	time.Sleep(8 * time.Second)
	stage = "record_stop"
	if err = request(base, tokenA, "POST", path+"/stop", map[string]any{}, nil); err != nil {
		return err
	}
	result, err := awaitRecording(base, tokenA, path, "ready")
	if err != nil {
		return err
	}
	stage = "signed_download"
	member, err := readRecording(base, tokenB, path)
	if err != nil {
		return err
	}
	if member.Status != "ready" || len(member.Files) == 0 {
		return errors.New("member_artifact_missing")
	}
	var receipt map[string]any
	for _, file := range result.Files {
		if file.FileType != "final_audio" {
			continue
		}
		if file.MimeType != "audio/mp4" || file.SizeBytes <= 0 || file.SizeBytes > 8<<20 || len(file.ChecksumSHA256) != 64 {
			return errors.New("artifact_metadata")
		}
		u, parseErr := url.Parse(file.URL)
		if parseErr != nil || u.Scheme != "https" || u.Host != os.Getenv("MEETSPACE_PROBE_OBJECT_HOST") || u.User != nil || u.Query().Get("X-Amz-Signature") == "" {
			return errors.New("signed_object_scope")
		}
		// Test-only known MinIO container speaks HTTP. Preserve signed host/path/query, never attach API auth.
		u.Scheme = "http"
		req, _ := http.NewRequest("GET", u.String(), nil)
		response, downloadErr := client.Do(req)
		if downloadErr != nil {
			return errors.New("signed_download")
		}
		bytes, readErr := io.ReadAll(io.LimitReader(response.Body, 8<<20+1))
		response.Body.Close()
		if readErr != nil || response.StatusCode != 200 || int64(len(bytes)) != file.SizeBytes {
			return errors.New("download_size_status")
		}
		sum := sha256.Sum256(bytes)
		digest := hex.EncodeToString(sum[:])
		if digest != strings.ToLower(file.ChecksumSHA256) {
			return errors.New("download_checksum")
		}
		if err = os.WriteFile("/evidence/recording.m4a", bytes, 0600); err != nil {
			return errors.New("artifact_write")
		}
		// Removing the signature must deny the same private object.
		u.RawQuery = ""
		unsigned, _ := http.NewRequest("GET", u.String(), nil)
		unsignedResponse, unsignedErr := client.Do(unsigned)
		if unsignedErr != nil {
			return errors.New("unsigned_request")
		}
		unsignedResponse.Body.Close()
		if unsignedResponse.StatusCode != 403 {
			return errors.New("unsigned_object_not_private")
		}
		receipt = map[string]any{"status": "ready", "mode": "audio_only", "source": "synthetic valid Opus silence, 20ms packets", "mimeType": file.MimeType, "serverFileName": file.FileName, "sizeBytes": file.SizeBytes, "sha256": digest, "durationSec": file.DurationSec, "downloadAuthentication": "fresh server-signed URL only; no account bearer/cookies", "signedGETStatus": 200, "unsignedGETStatus": 403}
		break
	}
	if receipt == nil {
		return errors.New("final_audio_missing")
	}
	stage = "access_revocation"
	if !denied(request(base, tokenC, "GET", path, nil, nil)) {
		return errors.New("ready_outsider_not_denied")
	}
	if err = request(base, tokenA, "POST", roomPath+"/participants/"+participantB+"/moderation", map[string]string{"action": "kick"}, nil); err != nil {
		return err
	}
	if !denied(request(base, tokenB, "GET", path, nil, nil)) {
		return errors.New("kicked_member_new_url_not_denied")
	}
	receipt["nonmemberAndRevokedMembershipDenied"] = true
	encoded, _ := json.MarshalIndent(receipt, "", "  ")
	if err = os.WriteFile("/evidence/artifact.json", append(encoded, '\n'), 0600); err != nil {
		return err
	}
	fmt.Println("PASS real ready audio artifact, signed download checksum/length, unsigned object 403, member access and nonmember/revoked-member denial")
	stage = "cleanup"
	publisher.close(false)
	if err = request(base, tokenA, "POST", roomPath+"/finish", map[string]any{}, nil); err != nil {
		return err
	}
	return nil
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL stage="+stage+" reason="+err.Error())
		os.Exit(1)
	}
	fmt.Println("PASS recording pipeline probe; real audio artifact from synthetic silence, no video/device/iOS playback claim")
}
